//go:build integration

// These tests talk to the real RabbitMQ and to the notifier container of the integration stack
// (scripts/integration-test.sh starts it and sets the environment). Run them with -tags integration.
package events

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"

	amqp "github.com/rabbitmq/amqp091-go"

	"github.com/Franklindot04/Multi-Cloud-SRE-Platform/apps/notifier/internal/platform"
)

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func dial(t *testing.T) *amqp.Channel {
	t.Helper()
	port, _ := strconv.Atoi(env("AMQP_PORT", "5672"))
	uri := amqp.URI{Scheme: "amqp", Host: env("AMQP_HOST", "localhost"), Port: port,
		Username: os.Getenv("AMQP_USER"), Password: os.Getenv("AMQP_PASSWORD"), Vhost: "/"}
	conn, err := amqp.Dial(uri.String())
	if err != nil {
		t.Fatalf("cannot reach RabbitMQ: %v", err)
	}
	t.Cleanup(func() { _ = conn.Close() })
	ch, err := conn.Channel()
	if err != nil {
		t.Fatal(err)
	}
	if err := ch.Confirm(false); err != nil {
		t.Fatal(err)
	}
	return ch
}

func publish(t *testing.T, ch *amqp.Channel, key string, headers amqp.Table, body []byte) {
	t.Helper()
	conf, err := ch.PublishWithDeferredConfirmWithContext(context.Background(), Exchange, key, true, false, amqp.Publishing{
		ContentType: "application/json", DeliveryMode: amqp.Persistent, Headers: headers, Body: body,
	})
	if err != nil {
		t.Fatal(err)
	}
	if ok, err := conf.WaitContext(context.Background()); err != nil || !ok {
		t.Fatalf("message not confirmed: %v", err)
	}
}

// metric returns a series value from the notifier's /metrics, for example metric(t, `messages_consumed_total{result="duplicate"}`).
func metric(t *testing.T, series string) float64 {
	t.Helper()
	resp, err := http.Get(env("NOTIFIER_URL", "http://localhost:8083") + "/metrics")
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = resp.Body.Close() }()
	b, _ := io.ReadAll(resp.Body)
	for _, line := range strings.Split(string(b), "\n") {
		if strings.HasPrefix(line, series+" ") {
			v, _ := strconv.ParseFloat(strings.Fields(line)[1], 64)
			return v
		}
	}
	t.Fatalf("series %s not found", series)
	return 0
}

func eventually(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(20 * time.Second)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(100 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", what)
}

func notificationExists(id string) bool {
	resp, err := http.Get(env("NOTIFIER_URL", "http://localhost:8083") + "/notifications/" + url.PathEscape(id))
	if err != nil {
		return false
	}
	_ = resp.Body.Close()
	return resp.StatusCode == http.StatusOK
}

func TestADuplicateEventIsRecordedOnce(t *testing.T) {
	ch := dial(t)
	id := platform.NewUUID()
	body := []byte(fmt.Sprintf(`{"event_id":%q,"type":"order.paid","schema_version":1,"occurred_at":"2026-01-02T03:04:05.000+00:00",`+
		`"aggregate_id":"o-dup","data":{"order_id":"o-dup","customer_id":"c","status":"paid","total_minor":100,"currency":"USD","payment_id":"p","failure_reason":null}}`, id))
	headers := amqp.Table{"event_id": id, "event_type": "order.paid", "schema_version": int32(1)}

	processed := metric(t, `messages_consumed_total{result="processed"}`)
	duplicates := metric(t, `messages_consumed_total{result="duplicate"}`)
	for i := 0; i < 3; i++ {
		publish(t, ch, "order.paid", headers, body)
	}
	eventually(t, "the notification to be recorded", func() bool { return notificationExists(id) })
	eventually(t, "both duplicates to be counted", func() bool {
		return metric(t, `messages_consumed_total{result="duplicate"}`)-duplicates >= 2
	})
	if got := metric(t, `messages_consumed_total{result="processed"}`) - processed; got != 1 {
		t.Fatalf("the event was processed %v times, want exactly once", got)
	}
}

func TestAPoisonMessageIsDeadLetteredWithItsReason(t *testing.T) {
	ch := dial(t)
	marker := "poison-" + platform.NewUUID()
	deadLetters := metric(t, `dead_letter_messages_total`)
	publish(t, ch, "order.paid", amqp.Table{"event_id": marker}, []byte("{this is not json "+marker))

	var found amqp.Delivery
	eventually(t, "the poison message to reach the dead-letter queue", func() bool {
		d, ok, err := ch.Get(DLQ, false)
		if err != nil || !ok {
			return false
		}
		if !strings.Contains(string(d.Body), marker) {
			_ = d.Nack(false, true) // someone else's message: put it back
			return false
		}
		found = d
		return true
	})
	defer func() { _ = found.Ack(false) }() // removes our test message from the queue
	if reason, _ := found.Headers["x-failure-reason"].(string); reason != "invalid_json" {
		t.Fatalf("x-failure-reason = %q, want invalid_json (headers: %v)", reason, found.Headers)
	}
	if headerString(found.Headers, "event_id") != marker || headerInt(found.Headers, "x-attempts") != 1 {
		t.Fatalf("unexpected headers: %v", found.Headers)
	}
	eventually(t, "the dead letter to be counted", func() bool { return metric(t, `dead_letter_messages_total`) > deadLetters })
}

func TestAnUnsupportedSchemaVersionIsDeadLettered(t *testing.T) {
	ch := dial(t)
	id := platform.NewUUID()
	body := []byte(fmt.Sprintf(`{"event_id":%q,"type":"order.paid","schema_version":99,"data":{"order_id":"o-future"}}`, id))
	publish(t, ch, "order.paid", amqp.Table{"event_id": id}, body)

	eventually(t, "the message to reach the dead-letter queue", func() bool {
		d, ok, err := ch.Get(DLQ, false)
		if err != nil || !ok {
			return false
		}
		if !strings.Contains(string(d.Body), id) {
			_ = d.Nack(false, true)
			return false
		}
		_ = d.Ack(false)
		reason, _ := d.Headers["x-failure-reason"].(string)
		if reason != "unsupported_schema_version_99" {
			t.Errorf("x-failure-reason = %q", reason)
		}
		return true
	})
	if notificationExists(id) {
		t.Fatal("a dead-lettered event must not be recorded")
	}
}
