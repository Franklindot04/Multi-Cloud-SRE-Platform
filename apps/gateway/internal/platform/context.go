package platform

import (
	"context"
	"net/http"
)

type ctxKey int

const (
	requestIDKey ctxKey = iota
	traceKey
)

// RequestID returns the request ID stored in ctx.
func RequestID(ctx context.Context) string {
	id, _ := ctx.Value(requestIDKey).(string)
	return id
}

// TraceFrom returns the trace stored in ctx.
func TraceFrom(ctx context.Context) Trace {
	t, _ := ctx.Value(traceKey).(Trace)
	return t
}

func withRequest(ctx context.Context, id string, t Trace) context.Context {
	return context.WithValue(context.WithValue(ctx, requestIDKey, id), traceKey, t)
}

// Propagate sets X-Request-Id and traceparent on an outbound request.
func Propagate(ctx context.Context, h http.Header) {
	if id := RequestID(ctx); id != "" {
		h.Set("X-Request-Id", id)
	}
	if t := TraceFrom(ctx); t.TraceID != "" {
		h.Set("traceparent", t.Outbound())
	}
}
