package events

import (
	"context"

	amqp "github.com/rabbitmq/amqp091-go"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/propagation"
	semconv "go.opentelemetry.io/otel/semconv/v1.43.0"
	"go.opentelemetry.io/otel/trace"
)

const tracerName = "github.com/Franklindot04/Multi-Cloud-SRE-Platform/apps/notifier/internal/events"

// headerCarrier lets a propagator read and write the W3C trace context (traceparent and tracestate) in the headers
// of a message. The producer may send the values as strings or as bytes.
type headerCarrier amqp.Table

// Get returns the header value, or "" when it is missing or not text.
func (c headerCarrier) Get(key string) string {
	switch v := c[key].(type) {
	case string:
		return v
	case []byte:
		return string(v)
	}
	return ""
}

// Set stores a header value.
func (c headerCarrier) Set(key, value string) { c[key] = value }

// Keys lists the header names.
func (c headerCarrier) Keys() []string {
	keys := make([]string, 0, len(c))
	for k := range c {
		keys = append(keys, k)
	}
	return keys
}

// tracing is the tracer provider and propagator a consumer uses. The zero value uses the global ones, which do
// nothing until platform.InitTracing has set them.
type tracing struct {
	provider    trace.TracerProvider
	propagators propagation.TextMapPropagator
}

func (t tracing) tracer() trace.Tracer {
	if t.provider != nil {
		return t.provider.Tracer(tracerName)
	}
	return otel.GetTracerProvider().Tracer(tracerName)
}

func (t tracing) propagator() propagation.TextMapPropagator {
	if t.propagators != nil {
		return t.propagators
	}
	return otel.GetTextMapPropagator()
}

// startConsume extracts the trace context from the message headers and starts the consumer span as a child of it.
// A message without a valid traceparent starts a new trace. The attributes are the broker's names for where the
// message came from; the body and the headers are never recorded.
func (t tracing) startConsume(ctx context.Context, d amqp.Delivery) (context.Context, trace.Span) {
	ctx = t.propagator().Extract(ctx, headerCarrier(d.Headers))
	return t.tracer().Start(ctx, Queue+" process",
		trace.WithSpanKind(trace.SpanKindConsumer),
		trace.WithAttributes(
			semconv.MessagingSystemRabbitMQ,
			semconv.MessagingOperationTypeProcess,
			semconv.MessagingDestinationName(d.Exchange),
			semconv.MessagingRabbitMQDestinationRoutingKey(d.RoutingKey),
			semconv.MessagingMessageBodySize(len(d.Body)),
		))
}

// startPublish starts a producer span for a message the notifier sends on, and writes its trace context into the
// headers, so the next consumer continues the same trace.
func (t tracing) startPublish(ctx context.Context, exchange, key string, headers amqp.Table) (context.Context, trace.Span) {
	destination := exchange
	if destination == "" {
		destination = key // the default exchange routes by queue name
	}
	ctx, span := t.tracer().Start(ctx, destination+" publish",
		trace.WithSpanKind(trace.SpanKindProducer),
		trace.WithAttributes(
			semconv.MessagingSystemRabbitMQ,
			semconv.MessagingOperationTypeSend,
			semconv.MessagingDestinationName(destination),
			semconv.MessagingRabbitMQDestinationRoutingKey(key),
		))
	t.propagator().Inject(ctx, headerCarrier(headers))
	return ctx, span
}

// fail marks a span as failed. The description is a short reason, never message content.
func fail(span trace.Span, err error, description string) {
	span.RecordError(err)
	span.SetStatus(codes.Error, description)
}

// startInternal starts a child span of the one in ctx, on the same provider. Without an active span it does nothing.
func startInternal(ctx context.Context, name string, attrs ...attribute.KeyValue) (context.Context, trace.Span) {
	parent := trace.SpanFromContext(ctx)
	return parent.TracerProvider().Tracer(tracerName).Start(ctx, name, trace.WithAttributes(attrs...))
}
