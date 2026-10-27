package platform

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/testutil"
)

func newStack(t *testing.T, fault FaultConfig, maxBody int64) (http.Handler, *Metrics, *bytes.Buffer) {
	t.Helper()
	var logs bytes.Buffer
	reg := prometheus.NewRegistry()
	metrics := NewMetrics("svc", reg)
	mux := http.NewServeMux()
	RegisterOps(mux, &Drain{}, reg, time.Second)
	mux.HandleFunc("GET /things/{id}", func(w http.ResponseWriter, r *http.Request) {
		WriteJSON(w, http.StatusOK, map[string]string{"id": r.PathValue("id"), "request_id": RequestID(r.Context())})
	})
	mux.HandleFunc("POST /things", func(w http.ResponseWriter, r *http.Request) {
		var v map[string]any
		if err := json.NewDecoder(r.Body).Decode(&v); err != nil {
			var tooLarge *http.MaxBytesError
			if errors.As(err, &tooLarge) {
				WriteError(w, r, http.StatusRequestEntityTooLarge, "payload_too_large", "too large")
				return
			}
			WriteError(w, r, http.StatusBadRequest, "invalid_json", "bad")
			return
		}
		WriteJSON(w, http.StatusCreated, v)
	})
	mux.HandleFunc("GET /boom", func(http.ResponseWriter, *http.Request) { panic("boom") })
	h := Wrap(mux, Options{Service: "svc", Logger: NewLogger(&logs, "svc", "info"), Metrics: metrics, MaxBody: maxBody, Fault: fault})
	return h, metrics, &logs
}

func do(h http.Handler, method, path, body string, headers map[string]string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

func TestRequestIDGeneratedAndEchoed(t *testing.T) {
	h, _, _ := newStack(t, FaultConfig{}, 1024)
	rec := do(h, "GET", "/things/1", "", nil)
	id := rec.Header().Get("X-Request-Id")
	if len(id) != 36 {
		t.Fatalf("expected a generated UUID, got %q", id)
	}
	rec = do(h, "GET", "/things/1", "", map[string]string{"X-Request-Id": "abc-123"})
	if got := rec.Header().Get("X-Request-Id"); got != "abc-123" {
		t.Fatalf("expected the inbound ID to be kept, got %q", got)
	}
	rec = do(h, "GET", "/things/1", "", map[string]string{"X-Request-Id": "bad id with spaces"})
	if got := rec.Header().Get("X-Request-Id"); got == "bad id with spaces" {
		t.Fatal("an invalid inbound request ID must be replaced")
	}
}

func TestRouteLabelUsesTemplateNotPath(t *testing.T) {
	h, m, _ := newStack(t, FaultConfig{}, 1024)
	do(h, "GET", "/things/a", "", nil)
	do(h, "GET", "/things/b", "", nil)
	do(h, "GET", "/does-not-exist", "", nil)

	if got := testutil.ToFloat64(m.Requests.WithLabelValues("svc", "GET", "/things/{id}", "200")); got != 2 {
		t.Fatalf("expected 2 requests on the route template, got %v", got)
	}
	if got := testutil.ToFloat64(m.Requests.WithLabelValues("svc", "GET", "unmatched", "404")); got != 1 {
		t.Fatalf("expected unmatched paths to share one label, got %v", got)
	}
	if testutil.CollectAndCount(m.Duration) == 0 {
		t.Fatal("expected duration observations")
	}
}

func TestInFlightReturnsToZero(t *testing.T) {
	h, m, _ := newStack(t, FaultConfig{}, 1024)
	do(h, "GET", "/things/1", "", nil)
	if got := testutil.ToFloat64(m.InFlight); got != 0 {
		t.Fatalf("in-flight gauge should be 0 after the request, got %v", got)
	}
}

func TestLogLineHasRequiredFields(t *testing.T) {
	h, _, logs := newStack(t, FaultConfig{}, 1024)
	do(h, "GET", "/things/9", "", map[string]string{"X-Request-Id": "req-1"})
	var line map[string]any
	if err := json.Unmarshal(bytes.TrimSpace(logs.Bytes()), &line); err != nil {
		t.Fatalf("log line is not JSON: %v: %s", err, logs.String())
	}
	for _, k := range []string{"timestamp", "level", "message", "service", "request_id", "method", "route", "status", "duration_ms", "trace_id"} {
		if _, ok := line[k]; !ok {
			t.Errorf("log line is missing %q: %v", k, line)
		}
	}
	if line["route"] != "/things/{id}" || line["request_id"] != "req-1" || line["service"] != "svc" || line["level"] != "info" {
		t.Errorf("unexpected log content: %v", line)
	}
}

func TestBodyLimit(t *testing.T) {
	h, _, _ := newStack(t, FaultConfig{}, 16)
	rec := do(h, "POST", "/things", `{"a":"`+strings.Repeat("x", 100)+`"}`, nil)
	if rec.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("expected 413, got %d", rec.Code)
	}
	rec = do(h, "POST", "/things", `{"a":1}`, nil)
	if rec.Code != http.StatusCreated {
		t.Fatalf("expected 201 for a small body, got %d", rec.Code)
	}
}

func TestPanicBecomes500(t *testing.T) {
	h, m, _ := newStack(t, FaultConfig{}, 1024)
	rec := do(h, "GET", "/boom", "", nil)
	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("expected 500, got %d", rec.Code)
	}
	if got := testutil.ToFloat64(m.InFlight); got != 0 {
		t.Fatalf("in-flight gauge leaked after a panic: %v", got)
	}
}

func TestFaultInjectionDisabledByDefault(t *testing.T) {
	h, _, _ := newStack(t, FaultConfig{Enabled: false, ErrorRate: 1, LatencyMs: 500}, 1024)
	start := time.Now()
	rec := do(h, "GET", "/things/1", "", nil)
	if rec.Code != http.StatusOK || time.Since(start) > 200*time.Millisecond {
		t.Fatalf("disabled fault injection must not change behaviour: %d in %v", rec.Code, time.Since(start))
	}
}

func TestFaultInjectionErrorsAndSparesOperationalEndpoints(t *testing.T) {
	h, _, _ := newStack(t, FaultConfig{Enabled: true, ErrorRate: 1}, 1024)
	if rec := do(h, "GET", "/things/1", "", nil); rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("expected an injected 503, got %d", rec.Code)
	}
	for _, p := range []string{"/healthz", "/readyz", "/metrics"} {
		if rec := do(h, "GET", p, "", nil); rec.Code != http.StatusOK {
			t.Errorf("%s must not be affected by fault injection, got %d", p, rec.Code)
		}
	}
}

func TestFaultInjectionLatency(t *testing.T) {
	h, _, _ := newStack(t, FaultConfig{Enabled: true, LatencyMs: 80}, 1024)
	start := time.Now()
	rec := do(h, "GET", "/things/1", "", nil)
	if rec.Code != http.StatusOK || time.Since(start) < 80*time.Millisecond {
		t.Fatalf("expected a delayed 200, got %d after %v", rec.Code, time.Since(start))
	}
	start = time.Now()
	do(h, "GET", "/healthz", "", nil)
	if time.Since(start) > 40*time.Millisecond {
		t.Fatal("/healthz must not be delayed")
	}
}

func TestTraceparent(t *testing.T) {
	in := "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
	tr, ok := ParseTraceparent(in)
	if !ok || tr.TraceID != "4bf92f3577b34da6a3ce929d0e0e4736" || tr.Flags != "01" {
		t.Fatalf("valid traceparent not parsed: %+v %v", tr, ok)
	}
	out := tr.Outbound()
	if out == in || !strings.HasPrefix(out, "00-4bf92f3577b34da6a3ce929d0e0e4736-") || !strings.HasSuffix(out, "-01") {
		t.Fatalf("outbound must keep the trace and use a new span: %s", out)
	}
	for _, bad := range []string{"", "garbage", "00-00000000000000000000000000000000-00f067aa0ba902b7-01", "00-4bf92f3577b34da6a3ce929d0e0e4736-0000000000000000-01", "01-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"} {
		if _, ok := ParseTraceparent(bad); ok {
			t.Errorf("%q must be rejected", bad)
		}
	}
}

func TestPropagateSetsHeaders(t *testing.T) {
	var gotID, gotTP string
	h, _, _ := newStack(t, FaultConfig{}, 1024)
	_ = h
	ctx := withRequest(context.Background(), "rid-7", Trace{TraceID: "4bf92f3577b34da6a3ce929d0e0e4736", Flags: "01"})
	hdr := http.Header{}
	Propagate(ctx, hdr)
	gotID, gotTP = hdr.Get("X-Request-Id"), hdr.Get("traceparent")
	if gotID != "rid-7" || !traceparentPattern.MatchString(gotTP) {
		t.Fatalf("headers not propagated: %q %q", gotID, gotTP)
	}
}

func TestInboundTraceKeptAcrossMiddleware(t *testing.T) {
	var seen string
	reg := prometheus.NewRegistry()
	mux := http.NewServeMux()
	mux.HandleFunc("GET /x", func(_ http.ResponseWriter, r *http.Request) { seen = TraceFrom(r.Context()).TraceID })
	var logs bytes.Buffer
	h := Wrap(mux, Options{Service: "svc", Logger: NewLogger(&logs, "svc", "info"), Metrics: NewMetrics("svc", reg), MaxBody: 10})
	do(h, "GET", "/x", "", map[string]string{"traceparent": "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"})
	if seen != "4bf92f3577b34da6a3ce929d0e0e4736" {
		t.Fatalf("trace ID not kept: %q", seen)
	}
}

func TestReadyzDrainingAndDependencies(t *testing.T) {
	reg := prometheus.NewRegistry()
	drain := &Drain{}
	mux := http.NewServeMux()
	RegisterOps(mux, drain, reg, 100*time.Millisecond,
		Check{Name: "required", Required: true, Fn: func(context.Context) error { return nil }},
		Check{Name: "optional", Required: false, Fn: func(context.Context) error { return errors.New("down") }},
	)
	rec := do(mux, "GET", "/readyz", "", nil)
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), "degraded") {
		t.Fatalf("an optional failure must degrade, not fail: %d %s", rec.Code, rec.Body.String())
	}

	mux2 := http.NewServeMux()
	RegisterOps(mux2, &Drain{}, prometheus.NewRegistry(), 100*time.Millisecond,
		Check{Name: "required", Required: true, Fn: func(context.Context) error { return errors.New("down") }})
	if rec := do(mux2, "GET", "/readyz", "", nil); rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("a failing required dependency must give 503, got %d", rec.Code)
	}

	drain.Start()
	rec = do(mux, "GET", "/readyz", "", nil)
	if rec.Code != http.StatusServiceUnavailable || !strings.Contains(rec.Body.String(), "draining") {
		t.Fatalf("a draining process must report 503: %d %s", rec.Code, rec.Body.String())
	}
	if rec := do(mux, "GET", "/healthz", "", nil); rec.Code != http.StatusOK {
		t.Fatal("/healthz must stay 200 while draining")
	}
}

func TestReadyzTimeoutOnSlowDependency(t *testing.T) {
	mux := http.NewServeMux()
	RegisterOps(mux, &Drain{}, prometheus.NewRegistry(), 50*time.Millisecond,
		Check{Name: "slow", Required: true, Fn: func(ctx context.Context) error {
			select {
			case <-time.After(2 * time.Second):
				return nil
			case <-ctx.Done():
				return ctx.Err()
			}
		}})
	start := time.Now()
	rec := do(mux, "GET", "/readyz", "", nil)
	if rec.Code != http.StatusServiceUnavailable || time.Since(start) > time.Second {
		t.Fatalf("a slow dependency must time out quickly: %d after %v", rec.Code, time.Since(start))
	}
}

func TestMetricsEndpointExposesSharedNames(t *testing.T) {
	h, _, _ := newStack(t, FaultConfig{}, 1024)
	do(h, "GET", "/things/1", "", nil)
	body := do(h, "GET", "/metrics", "", nil).Body.String()
	for _, name := range []string{"http_requests_total", "http_request_duration_seconds_bucket", "http_requests_in_flight"} {
		if !strings.Contains(body, name) {
			t.Errorf("/metrics is missing %s", name)
		}
	}
}

func TestEnv(t *testing.T) {
	e := NewEnvFrom(map[string]string{"A": "12", "B": "nope", "C": "2.5", "D": "maybe", "E": "ftp://x", "F": "other"})
	if e.Int("A", 1, 0, 100) != 12 || e.Int("MISSING", 7, 0, 100) != 7 {
		t.Fatal("Int defaults or parsing are wrong")
	}
	e.Int("B", 1, 0, 100)
	e.Float("C", 0, 0, 1)
	e.Bool("D", false)
	e.URL("E", "http://x")
	e.OneOf("F", "a", "a", "b")
	err := e.Err()
	if err == nil {
		t.Fatal("expected validation errors")
	}
	for _, key := range []string{"B must", "C must", "D must", "E must", "F must"} {
		if !strings.Contains(err.Error(), key) {
			t.Errorf("error should mention %q: %v", key, err)
		}
	}
	if NewEnvFrom(map[string]string{"X": "  "}).String("X", "def") != "def" {
		t.Fatal("blank values should fall back to the default")
	}
	if got := NewEnvFrom(map[string]string{"U": "http://h:1/"}).URL("U", ""); got != "http://h:1" {
		t.Fatalf("trailing slash should be trimmed: %q", got)
	}
}

func TestLoggerLevelFallback(t *testing.T) {
	var b bytes.Buffer
	l := NewLogger(&b, "svc", "not-a-level")
	l.Debug("hidden")
	l.Info("shown")
	if strings.Contains(b.String(), "hidden") || !strings.Contains(b.String(), "shown") {
		t.Fatalf("unknown levels should fall back to info: %s", b.String())
	}
}
