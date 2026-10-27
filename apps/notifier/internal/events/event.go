// Package events consumes the order events that the orders service publishes to RabbitMQ.
package events

import (
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"time"
)

// SchemaVersion is the only event schema this consumer understands.
const SchemaVersion = 1

var (
	uuidPattern = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)
	knownTypes  = map[string]bool{"order.created": true, "order.paid": true, "order.failed": true}
)

// Event is the JSON body of a message on the platform.events exchange.
type Event struct {
	EventID       string    `json:"event_id"`
	Type          string    `json:"type"`
	SchemaVersion int       `json:"schema_version"`
	OccurredAt    time.Time `json:"occurred_at"`
	AggregateID   string    `json:"aggregate_id"`
	Data          struct {
		OrderID       string  `json:"order_id"`
		CustomerID    string  `json:"customer_id"`
		Status        string  `json:"status"`
		TotalMinor    int64   `json:"total_minor"`
		Currency      string  `json:"currency"`
		PaymentID     *string `json:"payment_id"`
		FailureReason *string `json:"failure_reason"`
	} `json:"data"`
}

// PermanentError marks a message that can never succeed, however often it is retried. It goes straight
// to the dead-letter queue.
type PermanentError struct{ Reason string }

func (e *PermanentError) Error() string { return e.Reason }

func permanent(format string, args ...any) error {
	return &PermanentError{Reason: fmt.Sprintf(format, args...)}
}

// IsPermanent reports whether err is a PermanentError.
func IsPermanent(err error) bool {
	var p *PermanentError
	return errors.As(err, &p)
}

// Parse decodes and validates a message body.
func Parse(body []byte) (Event, error) {
	var ev Event
	if err := json.Unmarshal(body, &ev); err != nil {
		return Event{}, permanent("invalid_json")
	}
	switch {
	case !uuidPattern.MatchString(ev.EventID):
		return Event{}, permanent("invalid_event_id")
	case ev.SchemaVersion != SchemaVersion:
		return Event{}, permanent("unsupported_schema_version_%d", ev.SchemaVersion)
	case !knownTypes[ev.Type]:
		return Event{}, permanent("unknown_event_type")
	case ev.Data.OrderID == "" || len(ev.Data.OrderID) > 64:
		return Event{}, permanent("invalid_order_id")
	}
	return ev, nil
}

// Message is the notification text for an event.
func (e Event) Message() string {
	switch e.Type {
	case "order.created":
		return fmt.Sprintf("Order %s was received", e.Data.OrderID)
	default:
		return fmt.Sprintf("Order %s is %s", e.Data.OrderID, e.Data.Status)
	}
}
