package events

import (
	"fmt"

	amqp "github.com/rabbitmq/amqp091-go"
)

// Names of the exchanges and queues. The orders service publishes to Exchange with the event type as the
// routing key. Everything here is declared idempotently by the consumer, so the order of deployment
// between orders and notifier does not matter.
const (
	Exchange   = "platform.events"
	Queue      = "notifier.orders"
	RetryQueue = "notifier.orders.retry"
	DLX        = "platform.events.dlx"
	DLQ        = "notifier.orders.dlq"
	BindingKey = "order.*"
)

// DeclareTopology creates the exchanges, queues and bindings if they do not exist:
//
//	platform.events (topic) --order.*--> notifier.orders --reject--> platform.events.dlx --> notifier.orders.dlq
//	notifier.orders.retry: messages wait retryDelayMs, then return to notifier.orders (via the default exchange)
//
// Queues are durable quorum queues. The retry queue has a message TTL and dead-letters back to the main
// queue, which is how a delayed retry works without a plugin.
func DeclareTopology(ch *amqp.Channel, retryDelayMs int) error {
	quorum := func(extra amqp.Table) amqp.Table {
		t := amqp.Table{"x-queue-type": "quorum"}
		for k, v := range extra {
			t[k] = v
		}
		return t
	}
	steps := []struct {
		name string
		fn   func() error
	}{
		{"exchange " + Exchange, func() error { return ch.ExchangeDeclare(Exchange, "topic", true, false, false, false, nil) }},
		{"exchange " + DLX, func() error { return ch.ExchangeDeclare(DLX, "direct", true, false, false, false, nil) }},
		{"queue " + DLQ, func() error {
			_, err := ch.QueueDeclare(DLQ, true, false, false, false, quorum(nil))
			return err
		}},
		{"bind " + DLQ, func() error { return ch.QueueBind(DLQ, Queue, DLX, false, nil) }},
		{"queue " + Queue, func() error {
			_, err := ch.QueueDeclare(Queue, true, false, false, false, quorum(amqp.Table{
				"x-dead-letter-exchange":    DLX,
				"x-dead-letter-routing-key": Queue,
			}))
			return err
		}},
		{"bind " + Queue, func() error { return ch.QueueBind(Queue, BindingKey, Exchange, false, nil) }},
		{"queue " + RetryQueue, func() error {
			_, err := ch.QueueDeclare(RetryQueue, true, false, false, false, quorum(amqp.Table{
				"x-message-ttl":             int32(retryDelayMs),
				"x-dead-letter-exchange":    "",
				"x-dead-letter-routing-key": Queue,
			}))
			return err
		}},
	}
	for _, s := range steps {
		if err := s.fn(); err != nil {
			return fmt.Errorf("declare %s: %w", s.name, err)
		}
	}
	return nil
}
