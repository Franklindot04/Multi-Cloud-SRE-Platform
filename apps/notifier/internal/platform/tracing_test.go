package platform

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"
	"go.opentelemetry.io/otel/trace"
)

const (
	remoteTrace = "4bf92f3577b34da6a3ce929d0e0e4736"
	remoteSpan  = "00f067aa0ba902b7"
)

// tracedStack is the middleware with a tracer provider that keeps its spans in memory.
func tracedStack(t *testing.T) (http.Handler, *tracetest.InMemoryExporter, *bytes.Buffer) {
	t.Helper()
	exporter := tracetest.NewInMemoryExporter()
	tp, err := NewTracerProvider(context.Background(), "svc", "1.2.3", sdktrace.WithSyncer(exporter))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = tp.Shutdown(context.Background()) })

	var logs bytes.Buffer
	reg := prometheus.NewRegistry()
	mux := http.NewServeMux()
	RegisterOps(mux, &Drain{}, reg, time.Second)
	mux.HandleFunc("GET /things/{id}", func(w http.ResponseWriter, r *http.Request) {
		WriteJSON(w, http.StatusOK, map[string]string{"id": r.PathValue("id")})
	})
	mux.HandleFunc("GET /fail", func(w http.ResponseWriter, r *http.Request) {
		WriteError(w, r, http.StatusInternalServerError, "internal_error", "failed")
	})
	mux.HandleFunc("GET /boom", func(http.ResponseWriter, *http.Request) { panic("secret value") })
	h := Wrap(mux, Options{
		Service: "svc", Logger: NewLogger(&logs, "svc", "info"), Metrics: NewMetrics("svc", reg), MaxBody: 1024,
		TracerProvider: tp, Propagators: Propagator(),
	})
	return h, exporter, &logs
}

func logTraceID(t *testing.T, logs *bytes.Buffer) string {
	t.Helper()
	lines := strings.Split(strings.TrimSpace(logs.String()), "\n")
	var line map[string]any
	if err := json.Unmarshal([]byte(lines[len(lines)-1]), &line); err != nil {
		t.Fatalf("log line is not JSON: %v", err)
	}
	id, _ := line["trace_id"].(string)
	return id
}

func TestServerSpanIsNamedAfterTheRouteAndContinuesTheIncomingTrace(t *testing.T) {
	h, exporter, _ := tracedStack(t)
	do(h, "GET", "/things/12345", "", map[string]string{"traceparent": "00-" + remoteTrace + "-" + remoteSpan + "-01"})

	spans := exporter.GetSpans()
	if len(spans) != 1 {
		t.Fatalf("expected one span, got %d", len(spans))
	}
	s := spans[0]
	if s.Name != "GET /things/{id}" || s.SpanKind != trace.SpanKindServer {
		t.Fatalf("got span %q of kind %v", s.Name, s.SpanKind)
	}
	if strings.Contains(s.Name, "12345") {
		t.Fatalf("the span name must not contain the id: %q", s.Name)
	}
	if s.SpanContext.TraceID().String() != remoteTrace || s.Parent.SpanID().String() != remoteSpan || !s.Parent.IsRemote() {
		t.Fatalf("span is not a child of the incoming traceparent: trace %s, parent %s", s.SpanContext.TraceID(), s.Parent.SpanID())
	}
	var route string
	for _, a := range s.Attributes {
		if a.Key == "http.route" {
			route = a.Value.AsString()
		}
	}
	if route != "/things/{id}" {
		t.Fatalf("http.route = %q", route)
	}
}

func TestLogTraceIDIsTheSpansTraceID(t *testing.T) {
	h, exporter, logs := tracedStack(t)
	pattern := regexp.MustCompile(`"trace_id":"[0-9a-f]{32}"`)

	// A request with no traceparent starts a trace: the log has the span's trace ID.
	do(h, "GET", "/things/1", "", nil)
	spans := exporter.GetSpans()
	if len(spans) != 1 {
		t.Fatalf("expected one span, got %d", len(spans))
	}
	if got, want := logTraceID(t, logs), spans[0].SpanContext.TraceID().String(); got != want {
		t.Fatalf("log trace_id %q, span trace %q", got, want)
	}
	if !pattern.MatchString(logs.String()) {
		t.Fatalf("trace_id is not 32 lower-case hex digits in %s", logs.String())
	}

	// A request that carries a traceparent keeps its trace.
	logs.Reset()
	do(h, "GET", "/things/2", "", map[string]string{"traceparent": "00-" + remoteTrace + "-" + remoteSpan + "-01"})
	if got := logTraceID(t, logs); got != remoteTrace {
		t.Fatalf("log trace_id %q, want the incoming %q", got, remoteTrace)
	}
}

func TestTheDefaultSamplerFollowsTheParent(t *testing.T) {
	h, exporter, logs := tracedStack(t)
	do(h, "GET", "/things/1", "", map[string]string{"traceparent": "00-" + remoteTrace + "-" + remoteSpan + "-00"})
	if n := len(exporter.GetSpans()); n != 0 {
		t.Fatalf("a request the caller did not sample must not be exported, got %d spans", n)
	}
	if got := logTraceID(t, logs); got != remoteTrace {
		t.Fatalf("the log still carries the trace ID, got %q", got)
	}
}

func TestOperationsEndpointsCreateNoSpans(t *testing.T) {
	h, exporter, _ := tracedStack(t)
	for _, path := range []string{"/healthz", "/readyz", "/metrics"} {
		if rec := do(h, "GET", path, "", nil); rec.Code != http.StatusOK {
			t.Fatalf("%s: status %d", path, rec.Code)
		}
	}
	if n := len(exporter.GetSpans()); n != 0 {
		t.Fatalf("expected no spans for the operations endpoints, got %d", n)
	}
}

func TestFailedAndPanickingRequestsMarkTheSpan(t *testing.T) {
	h, exporter, _ := tracedStack(t)
	do(h, "GET", "/fail", "", nil)
	do(h, "GET", "/boom", "", nil)
	spans := exporter.GetSpans()
	if len(spans) != 2 {
		t.Fatalf("expected two spans, got %d", len(spans))
	}
	for _, s := range spans {
		if s.Status.Code != codes.Error {
			t.Errorf("%s: status %v, want error", s.Name, s.Status.Code)
		}
	}
	for _, s := range spans {
		for _, e := range s.Events {
			for _, a := range e.Attributes {
				if strings.Contains(a.Value.Emit(), "secret value") {
					t.Errorf("the panic value must not be recorded: %v", a)
				}
			}
		}
	}
}

func TestResourceHasServiceNameVersionAndNamespace(t *testing.T) {
	t.Setenv("OTEL_RESOURCE_ATTRIBUTES", "service.namespace=shop")
	exporter := tracetest.NewInMemoryExporter()
	tp, err := NewTracerProvider(context.Background(), "svc", "1.2.3", sdktrace.WithSyncer(exporter))
	if err != nil {
		t.Fatal(err)
	}
	_, span := tp.Tracer("t").Start(context.Background(), "x")
	span.End()
	got := map[string]string{}
	for _, kv := range exporter.GetSpans()[0].Resource.Attributes() {
		got[string(kv.Key)] = kv.Value.Emit()
	}
	for key, want := range map[string]string{"service.name": "svc", "service.version": "1.2.3", "service.namespace": "shop"} {
		if got[key] != want {
			t.Errorf("%s = %q, want %q", key, got[key], want)
		}
	}

	t.Setenv("OTEL_SERVICE_NAME", "renamed")
	tp, _ = NewTracerProvider(context.Background(), "svc", "1.2.3", sdktrace.WithSyncer(exporter))
	exporter.Reset()
	_, span = tp.Tracer("t").Start(context.Background(), "x")
	span.End()
	if v, _ := exporter.GetSpans()[0].Resource.Set().Value(attribute.Key("service.name")); v.AsString() != "renamed" {
		t.Errorf("OTEL_SERVICE_NAME was not used: %v", v.Emit())
	}
}

func TestTracingIsOffUnlessAnEndpointIsConfigured(t *testing.T) {
	cases := []struct {
		name string
		env  map[string]string
		want bool
	}{
		{"nothing set", nil, false},
		{"endpoint", map[string]string{"OTEL_EXPORTER_OTLP_ENDPOINT": "http://collector:4317"}, true},
		{"traces endpoint", map[string]string{"OTEL_EXPORTER_OTLP_TRACES_ENDPOINT": "http://collector:4317"}, true},
		{"sdk disabled", map[string]string{"OTEL_EXPORTER_OTLP_ENDPOINT": "http://collector:4317", "OTEL_SDK_DISABLED": "true"}, false},
		{"exporter none", map[string]string{"OTEL_EXPORTER_OTLP_ENDPOINT": "http://collector:4317", "OTEL_TRACES_EXPORTER": "none"}, false},
		{"empty endpoint", map[string]string{"OTEL_EXPORTER_OTLP_ENDPOINT": " "}, false},
	}
	for _, c := range cases {
		if got := TracingEnabled(NewEnvFrom(c.env)); got != c.want {
			t.Errorf("%s: enabled = %v, want %v", c.name, got, c.want)
		}
	}
}

func TestInitTracingWithoutAnEndpointSetsUpNoExporter(t *testing.T) {
	before := otel.GetTracerProvider()
	shutdown, err := InitTracing(context.Background(), NewEnvFrom(nil), "svc", "1", NewLogger(&bytes.Buffer{}, "svc", "info"))
	if err != nil {
		t.Fatal(err)
	}
	if _, isSDK := otel.GetTracerProvider().(*sdktrace.TracerProvider); isSDK || otel.GetTracerProvider() != before {
		t.Fatal("no tracer provider should be installed without an endpoint")
	}
	if err := shutdown(context.Background()); err != nil {
		t.Fatalf("shutdown of a disabled tracer: %v", err)
	}
	// Propagation works regardless, so a trace passes through a service that does not export.
	if fields := otel.GetTextMapPropagator().Fields(); len(fields) == 0 {
		t.Fatal("the W3C propagator should be set")
	}
}

func TestAnUnreachableCollectorDoesNotBlockStartupRequestsOrShutdown(t *testing.T) {
	before, beforeProp := otel.GetTracerProvider(), otel.GetTextMapPropagator()
	t.Cleanup(func() { otel.SetTracerProvider(before); otel.SetTextMapPropagator(beforeProp) })
	t.Setenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://127.0.0.1:1") // nothing listens here

	started := time.Now()
	var logs bytes.Buffer
	shutdown, err := InitTracing(context.Background(), NewEnv(), "svc", "1", NewLogger(&logs, "svc", "info"))
	if err != nil {
		t.Fatal(err)
	}
	if _, isSDK := otel.GetTracerProvider().(*sdktrace.TracerProvider); !isSDK {
		t.Fatal("tracing should be on when an endpoint is set")
	}

	tp, _ := otel.GetTracerProvider().(*sdktrace.TracerProvider)
	reg := prometheus.NewRegistry()
	mux := http.NewServeMux()
	mux.HandleFunc("GET /x", func(w http.ResponseWriter, _ *http.Request) { WriteJSON(w, http.StatusOK, map[string]string{}) })
	h := Wrap(mux, Options{Service: "svc", Logger: NewLogger(&logs, "svc", "info"), Metrics: NewMetrics("svc", reg), TracerProvider: tp})
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("GET", "/x", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("request failed with %d", rec.Code)
	}

	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	_ = shutdown(ctx) // may report the failed export; it must return within the deadline
	if elapsed := time.Since(started); elapsed > 4*time.Second {
		t.Fatalf("startup, request and shutdown took %v", elapsed)
	}
}
