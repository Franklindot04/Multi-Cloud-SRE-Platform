package notifications

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus"

	"github.com/Franklindot04/Multi-Cloud-SRE-Platform/apps/notifier/internal/platform"
)

func newHandler(t *testing.T, fault platform.FaultConfig, repo Repository) http.Handler {
	t.Helper()
	mux := http.NewServeMux()
	(&Handler{Repo: repo, Now: func() time.Time { return time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC) }}).Register(mux)
	reg := prometheus.NewRegistry()
	return platform.Wrap(mux, platform.Options{
		Service: "notifier", Logger: platform.NewLogger(&bytes.Buffer{}, "notifier", "info"),
		Metrics: platform.NewMetrics("notifier", reg), MaxBody: 2048, Fault: fault,
	})
}

func post(h http.Handler, body string) *httptest.ResponseRecorder {
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/notifications", strings.NewReader(body)))
	return rec
}

func TestCreateAndGet(t *testing.T) {
	h := newHandler(t, platform.FaultConfig{}, NewMemoryRepository(10))
	rec := post(h, `{"order_id":"o-1","channel":"email","message":"Your order is confirmed"}`)
	if rec.Code != http.StatusCreated {
		t.Fatalf("expected 201, got %d: %s", rec.Code, rec.Body.String())
	}
	var n Notification
	if err := json.Unmarshal(rec.Body.Bytes(), &n); err != nil {
		t.Fatal(err)
	}
	if n.ID == "" || n.Status != "recorded" || n.OrderID != "o-1" || n.Channel != "email" || !n.CreatedAt.Equal(time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)) {
		t.Fatalf("unexpected notification: %+v", n)
	}

	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/notifications/"+n.ID, nil))
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), n.ID) {
		t.Fatalf("expected the stored notification, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestGetUnknownIs404(t *testing.T) {
	h := newHandler(t, platform.FaultConfig{}, NewMemoryRepository(10))
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/notifications/nope", nil))
	if rec.Code != http.StatusNotFound || !strings.Contains(rec.Body.String(), `"code":"not_found"`) {
		t.Fatalf("expected a not_found error, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestValidation(t *testing.T) {
	h := newHandler(t, platform.FaultConfig{}, NewMemoryRepository(10))
	cases := map[string]string{
		"missing order": `{"channel":"email","message":"hi"}`,
		"bad channel":   `{"order_id":"o","channel":"pigeon","message":"hi"}`,
		"empty message": `{"order_id":"o","channel":"sms","message":"  "}`,
		"long message":  fmt.Sprintf(`{"order_id":"o","channel":"sms","message":%q}`, strings.Repeat("x", 1001)),
		"long order id": fmt.Sprintf(`{"order_id":%q,"channel":"sms","message":"hi"}`, strings.Repeat("x", 65)),
	}
	for name, body := range cases {
		if rec := post(h, body); rec.Code != http.StatusUnprocessableEntity {
			t.Errorf("%s: expected 422, got %d: %s", name, rec.Code, rec.Body.String())
		}
	}
}

func TestMalformedAndOversizedBodies(t *testing.T) {
	h := newHandler(t, platform.FaultConfig{}, NewMemoryRepository(10))
	if rec := post(h, `{not json`); rec.Code != http.StatusBadRequest {
		t.Errorf("malformed JSON: expected 400, got %d", rec.Code)
	}
	if rec := post(h, `{"order_id":"o","channel":"sms","message":"hi","extra":1}`); rec.Code != http.StatusBadRequest {
		t.Errorf("unknown fields: expected 400, got %d", rec.Code)
	}
	big := fmt.Sprintf(`{"order_id":"o","channel":"sms","message":%q}`, strings.Repeat("x", 5000))
	if rec := post(h, big); rec.Code != http.StatusRequestEntityTooLarge {
		t.Errorf("oversized body: expected 413, got %d", rec.Code)
	}
}

type failingRepo struct{}

func (failingRepo) Create(context.Context, Notification) error { return fmt.Errorf("disk on fire") }
func (failingRepo) Get(context.Context, string) (Notification, bool, error) {
	return Notification{}, false, fmt.Errorf("disk on fire")
}

func TestStorageFailureIs503(t *testing.T) {
	h := newHandler(t, platform.FaultConfig{}, failingRepo{})
	if rec := post(h, `{"order_id":"o","channel":"sms","message":"hi"}`); rec.Code != http.StatusServiceUnavailable {
		t.Errorf("create: expected 503, got %d", rec.Code)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/notifications/x", nil))
	if rec.Code != http.StatusServiceUnavailable {
		t.Errorf("get: expected 503, got %d", rec.Code)
	}
}

func TestFaultInjectionToggle(t *testing.T) {
	on := newHandler(t, platform.FaultConfig{Enabled: true, ErrorRate: 1}, NewMemoryRepository(10))
	if rec := post(on, `{"order_id":"o","channel":"sms","message":"hi"}`); rec.Code != http.StatusServiceUnavailable || !strings.Contains(rec.Body.String(), "fault_injected") {
		t.Errorf("enabled: expected an injected 503, got %d: %s", rec.Code, rec.Body.String())
	}
	off := newHandler(t, platform.FaultConfig{Enabled: false, ErrorRate: 1}, NewMemoryRepository(10))
	if rec := post(off, `{"order_id":"o","channel":"sms","message":"hi"}`); rec.Code != http.StatusCreated {
		t.Errorf("disabled: expected 201, got %d", rec.Code)
	}
}

func TestMemoryRepositoryEvictsOldest(t *testing.T) {
	r := NewMemoryRepository(2)
	ctx := context.Background()
	for _, id := range []string{"a", "b", "c"} {
		if err := r.Create(ctx, Notification{ID: id}); err != nil {
			t.Fatal(err)
		}
	}
	if _, ok, _ := r.Get(ctx, "a"); ok {
		t.Error("the oldest entry should have been evicted")
	}
	if _, ok, _ := r.Get(ctx, "c"); !ok {
		t.Error("the newest entry should be kept")
	}
}

func TestMemoryRepositoryIsThreadSafe(t *testing.T) {
	r := NewMemoryRepository(1000)
	var wg sync.WaitGroup
	for i := 0; i < 50; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			id := fmt.Sprintf("n-%d", i)
			_ = r.Create(context.Background(), Notification{ID: id})
			_, _, _ = r.Get(context.Background(), id)
		}()
	}
	wg.Wait()
	for i := 0; i < 50; i++ {
		if _, ok, _ := r.Get(context.Background(), fmt.Sprintf("n-%d", i)); !ok {
			t.Errorf("missing n-%d", i)
		}
	}
}
