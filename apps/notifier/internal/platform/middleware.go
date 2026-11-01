package platform

import (
	"errors"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/trace"
)

// Options configures the shared middleware.
type Options struct {
	Service  string
	Logger   *slog.Logger
	Metrics  *Metrics
	MaxBody  int64
	Fault    FaultConfig
	Registry *prometheus.Registry

	// TracerProvider and Propagators are used for the server span of each request. Nil means the global ones, which
	// are no-ops until InitTracing has run.
	TracerProvider trace.TracerProvider
	Propagators    propagation.TextMapPropagator
}

type statusWriter struct {
	http.ResponseWriter
	status int
}

func (s *statusWriter) WriteHeader(code int) {
	s.status = code
	s.ResponseWriter.WriteHeader(code)
}

// routeOf returns the matched route template, never the raw path, to keep label cardinality bounded.
func routeOf(r *http.Request) string {
	p := r.Pattern
	if p == "" {
		return "unmatched"
	}
	if i := strings.IndexByte(p, ' '); i >= 0 {
		p = p[i+1:]
	}
	return p
}

// Wrap adds the behaviour every service shares: request ID and trace handling, body size limits,
// fault injection, panic recovery, Prometheus metrics and one structured log line per request. Every request
// except the operations endpoints also gets a server span; the logged trace_id is that span's trace when there is
// one, so a log line can be found from a trace and the other way round.
func Wrap(next http.Handler, o Options) http.Handler {
	inner := faults(o.Fault, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Body != nil && o.MaxBody > 0 {
			r.Body = http.MaxBytesReader(w, r.Body, o.MaxBody)
		}
		next.ServeHTTP(w, r)
	}))

	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()

		id := r.Header.Get("X-Request-Id")
		if !ValidRequestID(id) {
			id = NewUUID()
		}
		tc, ok := traceFromSpan(r.Context())
		if !ok {
			// Tracing is off, or this is an operations endpoint: keep the trace of the traceparent header.
			if tc, ok = ParseTraceparent(r.Header.Get("traceparent")); !ok {
				tc = NewTrace()
			}
		}
		w.Header().Set("X-Request-Id", id)
		r = r.WithContext(withRequest(r.Context(), id, tc))

		o.Metrics.InFlight.Inc()
		sw := &statusWriter{ResponseWriter: w, status: http.StatusOK}
		defer func() {
			if rec := recover(); rec != nil {
				o.Logger.Error("panic while handling request", "request_id", id, "panic", rec)
				span := trace.SpanFromContext(r.Context())
				span.RecordError(errors.New("panic while handling request"))
				span.SetStatus(codes.Error, "panic")
				if sw.status == http.StatusOK {
					WriteError(sw, r, http.StatusInternalServerError, "internal_error", "internal error")
				}
			}
			o.Metrics.InFlight.Dec()
			elapsed := time.Since(start)
			route := routeOf(r)
			nameServerSpan(r.Context(), r.Method, route)
			o.Metrics.Requests.WithLabelValues(o.Service, r.Method, route, strconv.Itoa(sw.status)).Inc()
			o.Metrics.Duration.WithLabelValues(o.Service, r.Method, route).Observe(elapsed.Seconds())
			o.Logger.Info("request",
				"request_id", id,
				"trace_id", tc.TraceID,
				"method", r.Method,
				"route", route,
				"status", sw.status,
				"duration_ms", float64(elapsed.Microseconds())/1000.0,
			)
		}()

		inner.ServeHTTP(sw, r)
	})
	return traceHandler(handler, o.Service, o.TracerProvider, o.Propagators)
}
