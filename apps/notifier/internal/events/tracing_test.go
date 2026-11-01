package events

import (
	"bytes"
	"context"
	"regexp"
	"strings"
	"testing"

	amqp "github.com/rabbitmq/amqp091-go"
	"go.opentelemetry.io/otel/codes"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"
	"go.opentelemetry.io/otel/trace"

	"github.com/Franklindot04/Multi-Cloud-SRE-Platform/apps/notifier/internal/notifications"
	"github.com/Franklindot04/Multi-Cloud-SRE-Platform/apps/notifier/internal/platform"
)

const (
	producerTrace = "4bf92f3577b34da6a3ce929d0e0e4736"
	producerSpan  = "00f067aa0ba902b7"
)

func memoryTracing(t *testing.T) (*Consumer, *tracetest.InMemoryExporter) {
	t.Helper()
	exporter := tracetest.NewInMemoryExporter()
	tp, err := platform.NewTracerProvider(context.Background(), "notifier", "1.2.3", sdktrace.WithSyncer(exporter))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = tp.Shutdown(context.Background()) })
	return &Consumer{TracerProvider: tp, Propagators: platform.Propagator()}, exporter
}

func delivery(headers amqp.Table) amqp.Delivery {
	return amqp.Delivery{Headers: headers, Exchange: "platform.events", RoutingKey: "order.paid", Body: body(eventID, "order.paid", 1)}
}

func TestConsumerSpanIsAChildOfTheTraceContextInTheMessageHeaders(t *testing.T) {
	traceparent := "00-" + producerTrace + "-" + producerSpan + "-01"
	for name, value := range map[string]any{"string header": traceparent, "bytes header": []byte(traceparent)} {
		c, exporter := memoryTracing(t)
		_, span := c.tracing().startConsume(context.Background(), delivery(amqp.Table{"traceparent": value}))
		span.End()

		spans := exporter.GetSpans()
		if len(spans) != 1 {
			t.Fatalf("%s: expected one span, got %d", name, len(spans))
		}
		s := spans[0]
		if s.SpanKind != trace.SpanKindConsumer || s.Name != Queue+" process" {
			t.Errorf("%s: got span %q of kind %v", name, s.Name, s.SpanKind)
		}
		if s.SpanContext.TraceID().String() != producerTrace || s.Parent.SpanID().String() != producerSpan || !s.Parent.IsRemote() {
			t.Errorf("%s: not a child of the producer: trace %s, parent %s", name, s.SpanContext.TraceID(), s.Parent.SpanID())
		}
	}
}

func TestConsumerSpanStartsANewTraceWithoutTraceContext(t *testing.T) {
	c, exporter := memoryTracing(t)
	for _, headers := range []amqp.Table{nil, {}, {"traceparent": "garbage"}, {"traceparent": 42}} {
		exporter.Reset()
		_, span := c.tracing().startConsume(context.Background(), delivery(headers))
		span.End()
		s := exporter.GetSpans()[0]
		if s.Parent.IsValid() || !s.SpanContext.TraceID().IsValid() {
			t.Errorf("headers %v: expected a new root span, got parent %v", headers, s.Parent)
		}
	}
}

func TestConsumerSpanAttributesLeaveOutTheBodyAndHeaders(t *testing.T) {
	c, exporter := memoryTracing(t)
	d := delivery(amqp.Table{"traceparent": "00-" + producerTrace + "-" + producerSpan + "-01", "request_id": "r-1", "event_id": eventID})
	_, span := c.tracing().startConsume(context.Background(), d)
	span.End()

	got := map[string]string{}
	for _, kv := range exporter.GetSpans()[0].Attributes {
		got[string(kv.Key)] = kv.Value.Emit()
	}
	want := map[string]string{
		"messaging.system": "rabbitmq", "messaging.operation.type": "process",
		"messaging.destination.name": "platform.events", "messaging.rabbitmq.destination.routing_key": "order.paid",
	}
	for k, v := range want {
		if got[k] != v {
			t.Errorf("%s = %q, want %q", k, got[k], v)
		}
	}
	// Only these attributes: no body, no headers, no IDs from the message.
	allowed := map[string]bool{"messaging.message.body.size": true}
	for k := range want {
		allowed[k] = true
	}
	for k := range got {
		if !allowed[k] {
			t.Errorf("unexpected attribute %s", k)
		}
	}
}

func TestHandlingAddsASpanUnderTheConsumerSpanAndRecordsFailures(t *testing.T) {
	c, exporter := memoryTracing(t)
	d := delivery(amqp.Table{"traceparent": "00-" + producerTrace + "-" + producerSpan + "-01"})

	ctx, consumeSpan := c.tracing().startConsume(context.Background(), d)
	p, _ := newProcessor(notifications.NewMemoryRepository(10), 3)
	if disp, _ := p.Handle(ctx, Delivery{Body: d.Body}); disp != Ack {
		t.Fatalf("got %v", disp)
	}
	consumeSpan.End()

	byName := map[string]tracetest.SpanStub{}
	for _, s := range exporter.GetSpans() {
		byName[s.Name] = s
	}
	record, ok := byName["record notification"]
	if !ok {
		t.Fatalf("no record span among %v", exporter.GetSpans())
	}
	if record.Parent.SpanID() != byName[Queue+" process"].SpanContext.SpanID() || record.SpanContext.TraceID().String() != producerTrace {
		t.Errorf("the record span is not under the consumer span in the producer's trace")
	}
	if record.Status.Code == codes.Error {
		t.Error("a successful record must not be marked as an error")
	}

	// A failing store marks the span.
	exporter.Reset()
	ctx, consumeSpan = c.tracing().startConsume(context.Background(), d)
	failing, _ := newProcessor(&flakyRepo{Repository: notifications.NewMemoryRepository(10), failures: 1}, 3)
	if disp, _ := failing.Handle(ctx, Delivery{Body: d.Body}); disp != Retry {
		t.Fatalf("got %v", disp)
	}
	consumeSpan.End()
	for _, s := range exporter.GetSpans() {
		if s.Name == "record notification" && s.Status.Code != codes.Error {
			t.Errorf("a failed record should have an error status, got %v", s.Status.Code)
		}
	}
}

func TestRepublishedMessagesCarryThePublishSpansContext(t *testing.T) {
	c, exporter := memoryTracing(t)
	ctx, parent := c.tracing().startConsume(context.Background(), delivery(amqp.Table{"traceparent": "00-" + producerTrace + "-" + producerSpan + "-01"}))
	headers := amqp.Table{"traceparent": "00-" + producerTrace + "-" + producerSpan + "-01", "x-attempts": int32(1)}

	_, publish := c.tracing().startPublish(ctx, "", RetryQueue, headers)
	publish.End()
	parent.End()

	var producer tracetest.SpanStub
	for _, s := range exporter.GetSpans() {
		if s.SpanKind == trace.SpanKindProducer {
			producer = s
		}
	}
	want := "00-" + producerTrace + "-" + producer.SpanContext.SpanID().String() + "-01"
	if got, _ := headers["traceparent"].(string); got != want {
		t.Fatalf("traceparent in the republished headers = %q, want %q", got, want)
	}
	if headers["x-attempts"] != int32(1) {
		t.Error("the other headers must be kept")
	}
}

func TestTracingOffLeavesTheProcessorWorking(t *testing.T) {
	// No tracer provider anywhere: the global no-op one is used, nothing is recorded and nothing fails.
	c := &Consumer{}
	ctx, span := c.tracing().startConsume(context.Background(), delivery(nil))
	defer span.End()
	p, m := newProcessor(notifications.NewMemoryRepository(10), 3)
	if disp, _ := p.Handle(ctx, Delivery{Body: body(eventID, "order.paid", 1)}); disp != Ack || count(m, ResultProcessed) != 1 {
		t.Fatalf("got %v", disp)
	}
}

func loggingProcessor(logs *bytes.Buffer) *Processor {
	p, _ := newProcessor(notifications.NewMemoryRepository(10), 3)
	p.Log = platform.NewLogger(logs, "notifier", "debug")
	return p
}

func TestLogLinesDuringHandlingCarryTheConsumerSpansTraceID(t *testing.T) {
	c, exporter := memoryTracing(t)
	ctx, span := c.tracing().startConsume(context.Background(), delivery(nil))
	var logs bytes.Buffer
	loggingProcessor(&logs).Handle(ctx, Delivery{Body: body(eventID, "order.paid", 1), RequestID: "r-1"})
	span.End()

	want := exporter.GetSpans()[0].SpanContext.TraceID().String()
	if !strings.Contains(logs.String(), `"trace_id":"`+want+`"`) {
		t.Fatalf("log line lacks the span's trace id %s: %s", want, logs.String())
	}
	if !regexp.MustCompile(`"trace_id":"[0-9a-f]{32}"`).MatchString(logs.String()) {
		t.Fatalf("trace_id is not 32 lower-case hex digits: %s", logs.String())
	}
}

func TestLogLinesWithoutTracingUseTheHeaderTraceOrOmitTheField(t *testing.T) {
	var logs bytes.Buffer
	p := loggingProcessor(&logs)
	p.Handle(context.Background(), Delivery{Body: body(eventID, "order.paid", 1), Trace: "00-" + producerTrace + "-" + producerSpan + "-01"})
	if !strings.Contains(logs.String(), `"trace_id":"`+producerTrace+`"`) {
		t.Fatalf("expected the id from the traceparent header: %s", logs.String())
	}

	logs.Reset()
	p.Handle(context.Background(), Delivery{Body: body("7f1d7a52-3a48-4c8e-9a53-0f4f7a8e1d12", "order.paid", 1)})
	if logs.Len() == 0 || strings.Contains(logs.String(), "trace_id") {
		t.Fatalf("expected log lines without trace_id: %s", logs.String())
	}
}
