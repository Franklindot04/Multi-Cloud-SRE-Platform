package events

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"testing"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/testutil"

	"github.com/Franklindot04/Multi-Cloud-SRE-Platform/apps/notifier/internal/notifications"
	"github.com/Franklindot04/Multi-Cloud-SRE-Platform/apps/notifier/internal/platform"
)

const eventID = "6f1d7a52-3a48-4c8e-9a53-0f4f7a8e1d11"

func body(id, typ string, version int) []byte {
	return []byte(fmt.Sprintf(`{"event_id":%q,"type":%q,"schema_version":%d,"occurred_at":"2026-01-02T03:04:05.000+00:00",`+
		`"aggregate_id":"o-1","data":{"order_id":"o-1","customer_id":"c","status":"paid","total_minor":2500,"currency":"USD","payment_id":"p","failure_reason":null}}`,
		id, typ, version))
}

type flakyRepo struct {
	notifications.Repository
	mu       sync.Mutex
	failures int
}

func (r *flakyRepo) Create(ctx context.Context, n notifications.Notification) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.failures > 0 {
		r.failures--
		return errors.New("storage down")
	}
	return r.Repository.Create(ctx, n)
}

func newProcessor(repo notifications.Repository, maxAttempts int) (*Processor, *Metrics) {
	m := NewMetrics(prometheus.NewRegistry())
	return &Processor{
		Repo: repo, Dedupe: NewDedupe(100), MaxAttempts: maxAttempts, Metrics: m,
		Log: platform.NewLogger(&bytes.Buffer{}, "notifier", "debug"),
	}, m
}

func count(m *Metrics, result string) float64 {
	return testutil.ToFloat64(m.Consumed.WithLabelValues(result))
}

func TestRecordsAnEventOnceUnderItsEventID(t *testing.T) {
	repo := notifications.NewMemoryRepository(10)
	p, m := newProcessor(repo, 3)
	disp, _ := p.Handle(context.Background(), Delivery{Body: body(eventID, "order.paid", 1)})
	if disp != Ack || count(m, ResultProcessed) != 1 {
		t.Fatalf("got %v, processed=%v", disp, count(m, ResultProcessed))
	}
	n, ok, _ := repo.Get(context.Background(), eventID)
	if !ok || n.OrderID != "o-1" || n.Message != "Order o-1 is paid" || n.Channel != "email" {
		t.Fatalf("unexpected notification %+v (found=%v)", n, ok)
	}
}

func TestADuplicateIsAcknowledgedAndNotHandledAgain(t *testing.T) {
	repo := &flakyRepo{Repository: notifications.NewMemoryRepository(10)}
	p, m := newProcessor(repo, 3)
	for i := 0; i < 3; i++ {
		if disp, _ := p.Handle(context.Background(), Delivery{Body: body(eventID, "order.paid", 1)}); disp != Ack {
			t.Fatalf("delivery %d: got %v", i, disp)
		}
	}
	if count(m, ResultProcessed) != 1 || count(m, ResultDuplicate) != 2 {
		t.Fatalf("processed=%v duplicate=%v", count(m, ResultProcessed), count(m, ResultDuplicate))
	}
}

func TestPoisonMessagesGoStraightToTheDeadLetterQueueWithAReason(t *testing.T) {
	cases := map[string]struct {
		body   []byte
		reason string
	}{
		"not json":       {[]byte("{nope"), "invalid_json"},
		"empty":          {nil, "invalid_json"},
		"bad event id":   {body("abc", "order.paid", 1), "invalid_event_id"},
		"future schema":  {body(eventID, "order.paid", 2), "unsupported_schema_version_2"},
		"unknown type":   {body(eventID, "order.shipped", 1), "unknown_event_type"},
		"missing fields": {[]byte(`{"event_id":"` + eventID + `","type":"order.paid","schema_version":1,"data":{}}`), "invalid_order_id"},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			p, _ := newProcessor(notifications.NewMemoryRepository(10), 3)
			disp, reason := p.Handle(context.Background(), Delivery{Body: tc.body})
			if disp != DeadLetter || reason != tc.reason {
				t.Fatalf("got %v %q, want dead letter %q", disp, reason, tc.reason)
			}
		})
	}
}

func TestATransientFailureRetriesThenSucceeds(t *testing.T) {
	repo := &flakyRepo{Repository: notifications.NewMemoryRepository(10), failures: 1}
	p, _ := newProcessor(repo, 3)
	disp, reason := p.Handle(context.Background(), Delivery{Body: body(eventID, "order.paid", 1), Attempts: 0})
	if disp != Retry || !strings.Contains(reason, "storage down") {
		t.Fatalf("got %v %q", disp, reason)
	}
	// The retry is a new delivery of the same event; the failed attempt must not have claimed the ID.
	if disp, _ := p.Handle(context.Background(), Delivery{Body: body(eventID, "order.paid", 1), Attempts: 1}); disp != Ack {
		t.Fatalf("retry should succeed, got %v", disp)
	}
}

func TestRetriesAreBounded(t *testing.T) {
	repo := &flakyRepo{Repository: notifications.NewMemoryRepository(10), failures: 100}
	p, _ := newProcessor(repo, 3)
	var last Disposition
	var reason string
	for attempt := 0; attempt < 3; attempt++ {
		last, reason = p.Handle(context.Background(), Delivery{Body: body(eventID, "order.paid", 1), Attempts: attempt})
	}
	if last != DeadLetter || !strings.HasPrefix(reason, "max_attempts_exceeded") {
		t.Fatalf("after 3 attempts got %v %q", last, reason)
	}
}

func TestDedupeIsBoundedAndForgetsTheOldest(t *testing.T) {
	d := NewDedupe(2)
	d.Begin("a")
	d.Begin("b")
	d.Begin("c") // evicts a
	if !d.Begin("a") {
		t.Fatal("a should have been forgotten")
	}
	if d.Begin("c") {
		t.Fatal("c should still be remembered")
	}
}

func TestDedupeAllowsOnlyOneConcurrentClaim(t *testing.T) {
	d := NewDedupe(100)
	var wins int
	var mu sync.Mutex
	var wg sync.WaitGroup
	for i := 0; i < 50; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if d.Begin("same") {
				mu.Lock()
				wins++
				mu.Unlock()
			}
		}()
	}
	wg.Wait()
	if wins != 1 {
		t.Fatalf("%d goroutines claimed the same event", wins)
	}
}

func TestCreatedEventsGetTheirOwnMessage(t *testing.T) {
	ev, err := Parse(body(eventID, "order.created", 1))
	if err != nil || ev.Message() != "Order o-1 was received" {
		t.Fatalf("got %q, %v", ev.Message(), err)
	}
}

func TestConsumerIsNotReadyUntilConnected(t *testing.T) {
	c := &Consumer{}
	if err := c.Ready(context.Background()); err == nil {
		t.Fatal("a consumer without a connection must not be ready")
	}
	if check := c.Check(); !check.Required || check.Name != "rabbitmq" {
		t.Fatalf("unexpected check %+v", check)
	}
}
