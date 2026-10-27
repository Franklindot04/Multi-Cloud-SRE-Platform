package proxy

import (
	"bytes"
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus"

	"github.com/Franklindot04/Multi-Cloud-SRE-Platform/apps/gateway/internal/platform"
)

type seen struct {
	mu      sync.Mutex
	method  string
	path    string
	uri     string
	query   string
	headers http.Header
	body    string
}

func upstream(t *testing.T, status int, reply string, s *seen) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		s.mu.Lock()
		s.method, s.path, s.uri, s.query, s.headers, s.body = r.Method, r.URL.Path, r.RequestURI, r.URL.RawQuery, r.Header.Clone(), string(b)
		s.mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = io.WriteString(w, reply)
	}))
	t.Cleanup(srv.Close)
	return srv
}

func newGateway(t *testing.T, ordersURL, paymentsURL string, timeout time.Duration, fault platform.FaultConfig) http.Handler {
	t.Helper()
	mux := http.NewServeMux()
	drain := &platform.Drain{}
	reg := prometheus.NewRegistry()
	probe := &http.Client{Timeout: 200 * time.Millisecond}
	platform.RegisterOps(mux, drain, reg, 200*time.Millisecond,
		platform.HTTPCheck("orders", ordersURL, probe, true),
		platform.HTTPCheck("payments", paymentsURL, probe, true))
	(&Gateway{OrdersURL: ordersURL, PaymentsURL: paymentsURL, Client: &http.Client{Timeout: timeout}, Version: "1.2.3", Commit: "abc"}).Register(mux)
	return platform.Wrap(mux, platform.Options{
		Service: "gateway", Logger: platform.NewLogger(&bytes.Buffer{}, "gateway", "info"),
		Metrics: platform.NewMetrics("gateway", reg), MaxBody: 1024, Fault: fault,
	})
}

func call(h http.Handler, method, target, body string, headers map[string]string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(method, target, strings.NewReader(body))
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

func TestCreateOrderIsProxiedWithStatusBodyAndHeaders(t *testing.T) {
	var o, p seen
	orders := upstream(t, http.StatusCreated, `{"id":"o-1","status":"paid"}`, &o)
	payments := upstream(t, 200, `{}`, &p)
	h := newGateway(t, orders.URL, payments.URL, time.Second, platform.FaultConfig{})

	rec := call(h, "POST", "/api/orders", `{"customer_id":"c"}`, map[string]string{
		"Content-Type": "application/json", "Idempotency-Key": "key-1", "X-Request-Id": "rid-1",
		"traceparent": "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01", "Cookie": "secret=1",
	})
	if rec.Code != http.StatusCreated || rec.Body.String() != `{"id":"o-1","status":"paid"}` {
		t.Fatalf("status and body must be relayed: %d %s", rec.Code, rec.Body.String())
	}
	if o.method != "POST" || o.path != "/orders" || o.body != `{"customer_id":"c"}` {
		t.Fatalf("unexpected upstream request: %s %s %s", o.method, o.path, o.body)
	}
	if o.headers.Get("Idempotency-Key") != "key-1" || o.headers.Get("X-Request-Id") != "rid-1" {
		t.Fatalf("headers not forwarded: %v", o.headers)
	}
	if tp := o.headers.Get("traceparent"); !strings.HasPrefix(tp, "00-4bf92f3577b34da6a3ce929d0e0e4736-") || strings.Contains(tp, "00f067aa0ba902b7") {
		t.Fatalf("expected the same trace with a new span, got %q", tp)
	}
	if o.headers.Get("Cookie") != "" {
		t.Fatal("unrelated client headers must not be forwarded")
	}
}

func TestUpstreamStatusesAreRelayed(t *testing.T) {
	for _, code := range []int{200, 202, 404, 422, 503} {
		var s seen
		orders := upstream(t, code, `{"error":{"code":"x"}}`, &s)
		payments := upstream(t, 200, `{}`, &seen{})
		h := newGateway(t, orders.URL, payments.URL, time.Second, platform.FaultConfig{})
		if rec := call(h, "GET", "/api/orders/abc", "", nil); rec.Code != code {
			t.Errorf("expected %d to be relayed, got %d", code, rec.Code)
		}
	}
}

func TestListOrdersKeepsQuery(t *testing.T) {
	var o seen
	orders := upstream(t, 200, `{"items":[]}`, &o)
	h := newGateway(t, orders.URL, upstream(t, 200, `{}`, &seen{}).URL, time.Second, platform.FaultConfig{})
	rec := call(h, "GET", "/api/orders?limit=5&offset=10", "", nil)
	if rec.Code != 200 || o.path != "/orders" || o.query != "limit=5&offset=10" {
		t.Fatalf("unexpected: %d %s ?%s", rec.Code, o.path, o.query)
	}
}

func TestGetPaymentGoesToPayments(t *testing.T) {
	var p seen
	payments := upstream(t, 200, `{"id":"p-1"}`, &p)
	h := newGateway(t, upstream(t, 200, `{}`, &seen{}).URL, payments.URL, time.Second, platform.FaultConfig{})
	if rec := call(h, "GET", "/api/payments/p-1", "", nil); rec.Code != 200 || p.path != "/payments/p-1" {
		t.Fatalf("unexpected: %d %s", rec.Code, p.path)
	}
}

func TestPathSegmentIsEscaped(t *testing.T) {
	var o seen
	orders := upstream(t, 404, `{}`, &o)
	h := newGateway(t, orders.URL, upstream(t, 200, `{}`, &seen{}).URL, time.Second, platform.FaultConfig{})
	call(h, "GET", "/api/orders/a%2Fb", "", nil)
	if o.uri != "/orders/a%2Fb" {
		t.Fatalf("the id must stay one escaped path segment upstream, got %q", o.uri)
	}
}

func TestUpstreamTimeoutIs504(t *testing.T) {
	slow := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		select {
		case <-time.After(2 * time.Second):
		case <-r.Context().Done():
		}
	}))
	t.Cleanup(slow.Close)
	h := newGateway(t, slow.URL, upstream(t, 200, `{}`, &seen{}).URL, 100*time.Millisecond, platform.FaultConfig{})
	start := time.Now()
	rec := call(h, "GET", "/api/orders", "", nil)
	if rec.Code != http.StatusGatewayTimeout || !strings.Contains(rec.Body.String(), "upstream_timeout") {
		t.Fatalf("expected 504 upstream_timeout, got %d: %s", rec.Code, rec.Body.String())
	}
	if time.Since(start) > time.Second {
		t.Fatal("the timeout was not enforced")
	}
}

func TestUpstreamDownIs502(t *testing.T) {
	dead := httptest.NewServer(http.NotFoundHandler())
	url := dead.URL
	dead.Close()
	h := newGateway(t, url, upstream(t, 200, `{}`, &seen{}).URL, time.Second, platform.FaultConfig{})
	rec := call(h, "GET", "/api/orders", "", nil)
	if rec.Code != http.StatusBadGateway || !strings.Contains(rec.Body.String(), "upstream_unavailable") {
		t.Fatalf("expected 502, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestOversizedBodyIs413(t *testing.T) {
	h := newGateway(t, upstream(t, 201, `{}`, &seen{}).URL, upstream(t, 200, `{}`, &seen{}).URL, time.Second, platform.FaultConfig{})
	rec := call(h, "POST", "/api/orders", strings.Repeat("x", 5000), nil)
	if rec.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("expected 413, got %d", rec.Code)
	}
}

func TestVersion(t *testing.T) {
	h := newGateway(t, upstream(t, 200, `{}`, &seen{}).URL, upstream(t, 200, `{}`, &seen{}).URL, time.Second, platform.FaultConfig{})
	rec := call(h, "GET", "/version", "", nil)
	if rec.Code != 200 || !strings.Contains(rec.Body.String(), `"version":"1.2.3"`) || !strings.Contains(rec.Body.String(), `"commit":"abc"`) {
		t.Fatalf("unexpected: %d %s", rec.Code, rec.Body.String())
	}
}

func TestReadyzReflectsDownstreams(t *testing.T) {
	ready := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(200) }))
	t.Cleanup(ready.Close)
	broken := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(503) }))
	t.Cleanup(broken.Close)

	if rec := call(newGateway(t, ready.URL, ready.URL, time.Second, platform.FaultConfig{}), "GET", "/readyz", "", nil); rec.Code != 200 {
		t.Fatalf("expected ready, got %d: %s", rec.Code, rec.Body.String())
	}
	rec := call(newGateway(t, ready.URL, broken.URL, time.Second, platform.FaultConfig{}), "GET", "/readyz", "", nil)
	if rec.Code != http.StatusServiceUnavailable || !strings.Contains(rec.Body.String(), "payments") {
		t.Fatalf("a failing downstream must make the gateway not ready: %d %s", rec.Code, rec.Body.String())
	}
	if rec := call(newGateway(t, ready.URL, broken.URL, time.Second, platform.FaultConfig{}), "GET", "/healthz", "", nil); rec.Code != 200 {
		t.Fatal("/healthz must not depend on downstreams")
	}
}

func TestReadyzTimesOutOnHungDownstream(t *testing.T) {
	hung := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		select {
		case <-time.After(3 * time.Second):
		case <-r.Context().Done():
		}
	}))
	t.Cleanup(hung.Close)
	start := time.Now()
	rec := call(newGateway(t, hung.URL, hung.URL, time.Second, platform.FaultConfig{}), "GET", "/readyz", "", nil)
	if rec.Code != http.StatusServiceUnavailable || time.Since(start) > time.Second {
		t.Fatalf("readiness must time out quickly: %d after %v", rec.Code, time.Since(start))
	}
}

func TestFaultInjectionToggle(t *testing.T) {
	var o seen
	orders := upstream(t, 200, `{}`, &o)
	payments := upstream(t, 200, `{}`, &seen{})
	on := newGateway(t, orders.URL, payments.URL, time.Second, platform.FaultConfig{Enabled: true, ErrorRate: 1})
	if rec := call(on, "GET", "/api/orders", "", nil); rec.Code != http.StatusServiceUnavailable || !strings.Contains(rec.Body.String(), "fault_injected") {
		t.Fatalf("expected an injected 503, got %d", rec.Code)
	}
	if rec := call(on, "GET", "/version", "", nil); rec.Code != 200 {
		t.Fatal("/version must not be affected")
	}
	off := newGateway(t, orders.URL, payments.URL, time.Second, platform.FaultConfig{Enabled: false, ErrorRate: 1})
	if rec := call(off, "GET", "/api/orders", "", nil); rec.Code != 200 {
		t.Fatalf("disabled: expected 200, got %d", rec.Code)
	}
}

func TestRequestContextCancellationStopsUpstreamCall(t *testing.T) {
	started := make(chan struct{})
	slow := httptest.NewServer(http.HandlerFunc(func(_ http.ResponseWriter, r *http.Request) {
		close(started)
		<-r.Context().Done()
	}))
	t.Cleanup(slow.Close)
	h := newGateway(t, slow.URL, slow.URL, 5*time.Second, platform.FaultConfig{})
	ctx, cancel := context.WithCancel(context.Background())
	req := httptest.NewRequest("GET", "/api/orders", nil).WithContext(ctx)
	done := make(chan struct{})
	go func() { h.ServeHTTP(httptest.NewRecorder(), req); close(done) }()
	<-started
	cancel()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("cancelling the client request should stop the upstream call")
	}
}
