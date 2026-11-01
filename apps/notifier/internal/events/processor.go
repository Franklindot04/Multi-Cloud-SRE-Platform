package events

import (
	"context"
	"errors"
	"log/slog"
	"time"

	"go.opentelemetry.io/otel/attribute"

	"github.com/Franklindot04/Multi-Cloud-SRE-Platform/apps/notifier/internal/notifications"
	"github.com/Franklindot04/Multi-Cloud-SRE-Platform/apps/notifier/internal/platform"
)

// Disposition is what to do with a message after handling it.
type Disposition int

// What happens to a message.
const (
	Ack Disposition = iota
	Retry
	DeadLetter
)

// Delivery is the part of an AMQP delivery the processor needs.
type Delivery struct {
	Body      []byte
	EventID   string // from the message headers, used only for logging when the body is unreadable
	RequestID string
	Trace     string
	Attempts  int // how many times handling this message has already failed
}

// Processor turns a delivery into a recorded notification, once per event ID.
type Processor struct {
	Repo        notifications.Repository
	Dedupe      *Dedupe
	MaxAttempts int
	Metrics     *Metrics
	Log         *slog.Logger
	Now         func() time.Time
}

// Handle processes one delivery and says what to do with it. It never returns an error: a failure is a
// retry or a dead letter, with the reason.
func (p *Processor) Handle(ctx context.Context, d Delivery) (Disposition, string) {
	fields := []any{"request_id", d.RequestID}
	if id := platform.LogTraceID(ctx, d.Trace); id != "" {
		fields = append(fields, "trace_id", id) // same name and format as the request log lines
	}
	base := p.Log.With(append(fields, "traceparent", d.Trace)...)

	ev, err := Parse(d.Body)
	if err != nil {
		var perm *PermanentError
		reason := "invalid_message"
		if errors.As(err, &perm) {
			reason = perm.Reason
		}
		base.Warn("poison message", "reason", reason, "event_id", d.EventID)
		return DeadLetter, reason
	}
	log := base.With("event_id", ev.EventID, "event_type", ev.Type, "order_id", ev.Data.OrderID)

	if !p.Dedupe.Begin(ev.EventID) {
		p.Metrics.Consumed.WithLabelValues(ResultDuplicate).Inc()
		log.Info("duplicate event ignored")
		return Ack, ""
	}

	err = p.record(ctx, ev)
	if err == nil {
		p.Metrics.Consumed.WithLabelValues(ResultProcessed).Inc()
		log.Info("event recorded")
		return Ack, ""
	}

	p.Dedupe.Abandon(ev.EventID)
	if IsPermanent(err) || d.Attempts+1 >= p.MaxAttempts {
		reason := err.Error()
		if !IsPermanent(err) {
			reason = "max_attempts_exceeded: " + reason
		}
		log.Error("giving up on event", "reason", reason, "attempts", d.Attempts+1)
		return DeadLetter, reason
	}
	log.Warn("handling failed, will retry", "error", err.Error(), "attempt", d.Attempts+1)
	return Retry, err.Error()
}

// record stores the notification. The notification ID is the event ID, so recording the same event
// twice (after a restart forgot the dedupe set) overwrites instead of duplicating.
func (p *Processor) record(ctx context.Context, ev Event) (err error) {
	ctx, span := startInternal(ctx, "record notification", attribute.String("notifier.event_type", ev.Type))
	defer func() {
		if err != nil {
			fail(span, err, "record failed")
		}
		span.End()
	}()
	now := time.Now
	if p.Now != nil {
		now = p.Now
	}
	return p.Repo.Create(ctx, notifications.Notification{
		ID:        ev.EventID,
		OrderID:   ev.Data.OrderID,
		Channel:   "email",
		Message:   ev.Message(),
		Status:    "recorded",
		CreatedAt: now().UTC(),
	})
}
