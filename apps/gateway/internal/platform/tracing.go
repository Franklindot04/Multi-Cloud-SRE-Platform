package platform

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"strings"
	"sync"
	"time"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.43.0"
	"go.opentelemetry.io/otel/trace"
)

// TracingFlushTimeout is how long shutdown waits for the spans that are still queued. A Collector that does
// not answer must not hold up the exit of the process.
const TracingFlushTimeout = 5 * time.Second

// errorLogInterval limits how often a failing exporter is mentioned in the log.
const errorLogInterval = time.Minute

// Propagator is the propagation format between services: W3C trace context plus baggage.
func Propagator() propagation.TextMapPropagator {
	return propagation.NewCompositeTextMapPropagator(propagation.TraceContext{}, propagation.Baggage{})
}

// TracingEnabled reports whether the environment asks for traces to be exported. Tracing is off unless
// OTEL_EXPORTER_OTLP_ENDPOINT or OTEL_EXPORTER_OTLP_TRACES_ENDPOINT is set, so local runs, tests and CI need no
// Collector. OTEL_SDK_DISABLED=true and OTEL_TRACES_EXPORTER=none turn it off even when an endpoint is set.
func TracingEnabled(env *Env) bool {
	if env.String("OTEL_SDK_DISABLED", "") == "true" || env.String("OTEL_TRACES_EXPORTER", "") == "none" {
		return false
	}
	return env.String("OTEL_EXPORTER_OTLP_ENDPOINT", "") != "" || env.String("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT", "") != ""
}

// NewTracerProvider builds a provider whose resource carries service.name, service.version and, when
// OTEL_RESOURCE_ATTRIBUTES sets it, service.namespace. OTEL_SERVICE_NAME and OTEL_RESOURCE_ATTRIBUTES override the
// defaults. Unless opts set one, the sampler comes from OTEL_TRACES_SAMPLER and OTEL_TRACES_SAMPLER_ARG; without them
// it is parent-based and samples everything.
func NewTracerProvider(ctx context.Context, service, version string, opts ...sdktrace.TracerProviderOption) (*sdktrace.TracerProvider, error) {
	res, err := resource.New(ctx,
		resource.WithAttributes(semconv.ServiceName(service), semconv.ServiceVersion(version)),
		resource.WithFromEnv(),
	)
	if err != nil {
		return nil, fmt.Errorf("build the tracing resource: %w", err)
	}
	return sdktrace.NewTracerProvider(append([]sdktrace.TracerProviderOption{sdktrace.WithResource(res)}, opts...)...), nil
}

// InitTracing sets the global propagator and, when tracing is enabled, a global tracer provider that exports
// batches of spans over OTLP/gRPC. The exporter reads the standard OTEL_EXPORTER_OTLP_* variables; an endpoint with
// the scheme http:// uses a plain connection (for in-cluster Collectors), https:// uses TLS.
//
// It never blocks and never fails the caller. The connection is made in the background, so an unreachable Collector
// costs the spans, not the requests. The returned function flushes and stops the exporter within the context's
// deadline; it is never nil. A non-nil error means tracing stays off.
func InitTracing(ctx context.Context, env *Env, service, version string, log *slog.Logger) (func(context.Context) error, error) {
	otel.SetTextMapPropagator(Propagator())
	noop := func(context.Context) error { return nil }
	if !TracingEnabled(env) {
		return noop, nil
	}
	exporter, err := otlptracegrpc.New(ctx)
	if err != nil {
		return noop, fmt.Errorf("create the OTLP trace exporter: %w", err)
	}
	tp, err := NewTracerProvider(ctx, service, version, sdktrace.WithBatcher(exporter))
	if err != nil {
		return noop, err
	}
	otel.SetTracerProvider(tp)
	otel.SetErrorHandler(newErrorHandler(log))
	return tp.Shutdown, nil
}

// newErrorHandler logs export failures as JSON lines, at most one a minute, instead of the default plain text.
func newErrorHandler(log *slog.Logger) otel.ErrorHandler {
	var mu sync.Mutex
	var last time.Time
	return otel.ErrorHandlerFunc(func(err error) {
		mu.Lock()
		due := time.Since(last) >= errorLogInterval
		if due {
			last = time.Now()
		}
		mu.Unlock()
		if due {
			log.Warn("tracing error", "error", err.Error())
		}
	})
}

// shouldTrace is false for the operations endpoints. Probes and scrapes arrive every few seconds and would drown
// the traces.
func shouldTrace(r *http.Request) bool {
	switch r.URL.Path {
	case "/healthz", "/readyz", "/metrics":
		return false
	}
	return true
}

// traceHandler wraps h in a server span for every request except the operations endpoints. The span is renamed by
// Wrap, once the mux has chosen a route. A nil provider or propagator means the global one.
func traceHandler(h http.Handler, service string, tp trace.TracerProvider, p propagation.TextMapPropagator) http.Handler {
	opts := []otelhttp.Option{otelhttp.WithFilter(shouldTrace)}
	if tp != nil {
		opts = append(opts, otelhttp.WithTracerProvider(tp))
	}
	if p != nil {
		opts = append(opts, otelhttp.WithPropagators(p))
	}
	return otelhttp.NewHandler(h, service, opts...)
}

// NewTracedTransport returns base wrapped so that every outgoing request gets a client span and carries the
// traceparent header of that span. A nil provider or propagator means the global one. The span is named after the
// method and the target host and port, which are few and fixed, never the path.
func NewTracedTransport(base http.RoundTripper, tp trace.TracerProvider, p propagation.TextMapPropagator) http.RoundTripper {
	if base == nil {
		base = http.DefaultTransport
	}
	opts := []otelhttp.Option{otelhttp.WithSpanNameFormatter(func(_ string, r *http.Request) string {
		return r.Method + " " + r.URL.Host
	})}
	if tp != nil {
		opts = append(opts, otelhttp.WithTracerProvider(tp))
	}
	if p != nil {
		opts = append(opts, otelhttp.WithPropagators(p))
	}
	return otelhttp.NewTransport(base, opts...)
}

// traceFromSpan returns the trace of the active span, if there is one. Its ID is the 32 lower-case hex digits that
// W3C trace context uses, which is the form the log field and the Grafana link expect.
func traceFromSpan(ctx context.Context) (Trace, bool) {
	sc := trace.SpanContextFromContext(ctx)
	if !sc.IsValid() {
		return Trace{}, false
	}
	return Trace{TraceID: sc.TraceID().String(), Flags: fmt.Sprintf("%02x", byte(sc.TraceFlags()))}, true
}

// nameServerSpan gives the server span the name "METHOD route" and records the route, once it is known.
func nameServerSpan(ctx context.Context, method, route string) {
	span := trace.SpanFromContext(ctx)
	if !span.IsRecording() {
		return
	}
	span.SetName(strings.TrimSpace(method + " " + route))
	span.SetAttributes(attribute.String("http.route", route))
}

// LogTraceID returns the trace ID to write in a log line: the active span's, or else the one in the traceparent
// header, as the request middleware does. It returns "" when neither is valid.
func LogTraceID(ctx context.Context, traceparent string) string {
	if t, ok := traceFromSpan(ctx); ok {
		return t.TraceID
	}
	if t, ok := ParseTraceparent(traceparent); ok {
		return t.TraceID
	}
	return ""
}
