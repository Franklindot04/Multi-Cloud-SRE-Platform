package events

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"math/rand/v2"
	"sync"
	"sync/atomic"
	"time"

	amqp "github.com/rabbitmq/amqp091-go"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/trace"

	"github.com/Franklindot04/Multi-Cloud-SRE-Platform/apps/notifier/internal/config"
	"github.com/Franklindot04/Multi-Cloud-SRE-Platform/apps/notifier/internal/platform"
)

const (
	handleTimeout  = 10 * time.Second
	confirmTimeout = 5 * time.Second
	inflightWait   = 15 * time.Second
	statsInterval  = 10 * time.Second
	heartbeat      = 10 * time.Second
)

// Consumer reads Queue with manual acknowledgements and a prefetch limit, retries a failing message a bounded
// number of times through a delay queue, and moves poison messages to the dead-letter queue with the reason.
// It reconnects with exponential backoff and, on shutdown, finishes the messages it has in flight.
type Consumer struct {
	Config config.AMQP
	Proc   *Processor
	Log    *slog.Logger

	// TracerProvider and Propagators are used for the span of each message. Nil means the global ones, which are
	// no-ops until platform.InitTracing has run.
	TracerProvider trace.TracerProvider
	Propagators    propagation.TextMapPropagator

	connected atomic.Bool
}

func (c *Consumer) tracing() tracing {
	return tracing{provider: c.TracerProvider, propagators: c.Propagators}
}

// Ready reports whether the consumer has a working broker connection.
func (c *Consumer) Ready(_ context.Context) error {
	if !c.connected.Load() {
		return errors.New("not connected to rabbitmq")
	}
	return nil
}

// Check is the readiness check for /readyz: RabbitMQ is required when the consumer is enabled.
func (c *Consumer) Check() platform.Check {
	return platform.Check{Name: "rabbitmq", Required: true, Fn: c.Ready}
}

// Run consumes until ctx is cancelled. It returns nil after a clean stop.
func (c *Consumer) Run(ctx context.Context) error {
	backoff := time.Second
	for ctx.Err() == nil {
		started := time.Now()
		err := c.session(ctx)
		c.setConnected(false)
		if ctx.Err() != nil {
			return nil
		}
		if time.Since(started) > 30*time.Second {
			backoff = time.Second // the last connection was healthy for a while
		}
		wait := backoff/2 + time.Duration(rand.Int64N(int64(backoff/2)+1)) // jitter: half to full backoff
		c.Log.Warn("rabbitmq session ended, reconnecting", "error", fmt.Sprint(err), "retry_in", wait.String())
		select {
		case <-ctx.Done():
			return nil
		case <-time.After(wait):
		}
		backoff = min(backoff*2, c.Config.MaxBackoff)
	}
	return nil
}

func (c *Consumer) setConnected(v bool) {
	c.connected.Store(v)
	if v {
		c.Proc.Metrics.Connected.Set(1)
	} else {
		c.Proc.Metrics.Connected.Set(0)
	}
}

func (c *Consumer) dial() (*amqp.Connection, error) {
	uri := amqp.URI{
		Scheme: "amqp", Host: c.Config.Host, Port: c.Config.Port,
		Username: c.Config.User, Password: c.Config.Password, Vhost: c.Config.VHost,
	}
	return amqp.DialConfig(uri.String(), amqp.Config{
		Dial:      amqp.DefaultDial(c.Config.ConnectTimeout),
		Heartbeat: heartbeat,
		Vhost:     c.Config.VHost,
		Properties: amqp.Table{
			"connection_name": "notifier",
		},
	})
}

// session runs one connection until it fails or ctx is cancelled.
func (c *Consumer) session(ctx context.Context) error {
	conn, err := c.dial()
	if err != nil {
		return fmt.Errorf("connect: %w", err)
	}
	defer func() { _ = conn.Close() }()
	closed := conn.NotifyClose(make(chan *amqp.Error, 1))

	ch, err := conn.Channel()
	if err != nil {
		return fmt.Errorf("open channel: %w", err)
	}
	pub, err := conn.Channel()
	if err != nil {
		return fmt.Errorf("open publish channel: %w", err)
	}
	if err := pub.Confirm(false); err != nil {
		return fmt.Errorf("enable publisher confirms: %w", err)
	}
	if err := DeclareTopology(ch, int(c.Config.RetryDelay.Milliseconds())); err != nil {
		return err
	}
	if err := ch.Qos(c.Config.Prefetch, 0, false); err != nil {
		return fmt.Errorf("set prefetch: %w", err)
	}
	tag := "notifier-" + platform.NewUUID()
	deliveries, err := ch.Consume(Queue, tag, false, false, false, false, nil)
	if err != nil {
		return fmt.Errorf("consume: %w", err)
	}
	c.setConnected(true)
	c.Log.Info("consuming", "queue", Queue, "prefetch", c.Config.Prefetch, "max_attempts", c.Config.MaxAttempts)

	stopStats := make(chan struct{})
	var statsDone sync.WaitGroup
	statsDone.Add(1)
	go func() {
		defer statsDone.Done()
		c.collectStats(conn, stopStats)
	}()
	defer func() {
		close(stopStats)
		statsDone.Wait()
	}()

	var inflight sync.WaitGroup
	for {
		select {
		case <-ctx.Done():
			// Stop new deliveries, then let the messages already taken finish and acknowledge.
			_ = ch.Cancel(tag, false)
			finished := make(chan struct{})
			go func() { inflight.Wait(); close(finished) }()
			select {
			case <-finished:
			case <-time.After(inflightWait):
				c.Log.Warn("messages still in flight at shutdown; the broker will redeliver them")
			}
			return nil
		case cerr := <-closed:
			inflight.Wait()
			return fmt.Errorf("connection closed: %v", cerr)
		case d, ok := <-deliveries:
			if !ok {
				inflight.Wait()
				return errors.New("delivery channel closed")
			}
			inflight.Add(1)
			go func() {
				defer inflight.Done()
				c.handle(pub, d)
			}()
		}
	}
}

func (c *Consumer) handle(pub *amqp.Channel, d amqp.Delivery) {
	ctx, cancel := context.WithTimeout(context.Background(), handleTimeout)
	defer cancel()
	ctx, span := c.tracing().startConsume(ctx, d)
	defer span.End()

	attempts := headerInt(d.Headers, "x-attempts")
	disp, reason := c.Proc.Handle(ctx, Delivery{
		Body:      d.Body,
		EventID:   headerString(d.Headers, "event_id"),
		RequestID: headerString(d.Headers, "request_id"),
		Trace:     headerString(d.Headers, "traceparent"),
		Attempts:  attempts,
	})

	if disp != Ack {
		fail(span, errors.New(reason), "message not processed")
	}

	m := c.Proc.Metrics
	switch disp {
	case Ack:
		_ = d.Ack(false)
	case Retry:
		if err := c.republish(ctx, pub, "", RetryQueue, d, attempts+1, reason); err != nil {
			// Could not hand the message on: put it back on the queue rather than lose it.
			c.Log.Error("could not schedule a retry; requeueing", "error", err.Error())
			m.Consumed.WithLabelValues(ResultError).Inc()
			_ = d.Nack(false, true)
			return
		}
		m.Consumed.WithLabelValues(ResultRetry).Inc()
		_ = d.Ack(false)
	case DeadLetter:
		if err := c.republish(ctx, pub, DLX, Queue, d, attempts+1, reason); err != nil {
			c.Log.Error("could not dead-letter; requeueing", "error", err.Error())
			m.Consumed.WithLabelValues(ResultError).Inc()
			_ = d.Nack(false, true)
			return
		}
		m.Consumed.WithLabelValues(ResultDeadLetter).Inc()
		m.DeadLetters.Inc()
		_ = d.Ack(false)
	}
}

// republish copies d to another exchange and waits for the broker to confirm it, so the original is only
// acknowledged once the copy is safe. The failure reason and attempt count travel in headers.
func (c *Consumer) republish(ctx context.Context, pub *amqp.Channel, exchange, key string, d amqp.Delivery, attempts int, reason string) (err error) {
	headers := amqp.Table{}
	for k, v := range d.Headers {
		headers[k] = v
	}
	headers["x-attempts"] = int32(attempts)
	headers["x-failure-reason"] = reason
	headers["x-original-routing-key"] = d.RoutingKey
	headers["x-failed-at"] = time.Now().UTC().Format(time.RFC3339)

	ctx, span := c.tracing().startPublish(ctx, exchange, key, headers)
	defer func() {
		if err != nil {
			fail(span, err, "publish failed")
		}
		span.End()
	}()
	cctx, cancel := context.WithTimeout(ctx, confirmTimeout)
	defer cancel()
	conf, err := pub.PublishWithDeferredConfirmWithContext(cctx, exchange, key, true, false, amqp.Publishing{
		Headers:      headers,
		ContentType:  d.ContentType,
		DeliveryMode: amqp.Persistent,
		MessageId:    d.MessageId,
		Timestamp:    d.Timestamp,
		Type:         d.Type,
		Body:         d.Body,
	})
	if err != nil {
		return err
	}
	acked, err := conf.WaitContext(cctx)
	if err != nil {
		return err
	}
	if !acked {
		return errors.New("broker did not confirm the message")
	}
	return nil
}

// collectStats publishes the queue depths as gauges until stop is closed.
func (c *Consumer) collectStats(conn *amqp.Connection, stop <-chan struct{}) {
	t := time.NewTicker(statsInterval)
	defer t.Stop()
	for {
		c.queueDepths(conn)
		select {
		case <-stop:
			return
		case <-t.C:
		}
	}
}

func (c *Consumer) queueDepths(conn *amqp.Connection) {
	for label, name := range map[string]string{"main": Queue, "retry": RetryQueue, "dead_letter": DLQ} {
		// A passive declare of a missing queue closes the channel, so use a fresh one each time.
		ch, err := conn.Channel()
		if err != nil {
			return
		}
		q, err := ch.QueueDeclarePassive(name, true, false, false, false, nil)
		_ = ch.Close()
		if err != nil {
			continue
		}
		c.Proc.Metrics.Queue.WithLabelValues(label).Set(float64(q.Messages))
	}
}

func headerString(h amqp.Table, key string) string {
	if v, ok := h[key].(string); ok {
		return v
	}
	return ""
}

func headerInt(h amqp.Table, key string) int {
	switch v := h[key].(type) {
	case int:
		return v
	case int8:
		return int(v)
	case int16:
		return int(v)
	case int32:
		return int(v)
	case int64:
		return int(v)
	case uint8:
		return int(v)
	case uint16:
		return int(v)
	case uint32:
		return int(v)
	}
	return 0
}
