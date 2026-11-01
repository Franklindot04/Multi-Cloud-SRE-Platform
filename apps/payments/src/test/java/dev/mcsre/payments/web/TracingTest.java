package dev.mcsre.payments.web;

import static dev.mcsre.payments.web.ApiTestSupport.BODY;
import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import dev.mcsre.payments.obs.JsonLog;
import dev.mcsre.payments.obs.ObservabilityFilter;
import dev.mcsre.payments.obs.Tracing;
import io.opentelemetry.api.common.AttributeKey;
import io.opentelemetry.api.trace.SpanKind;
import io.opentelemetry.api.trace.StatusCode;
import io.opentelemetry.sdk.testing.exporter.InMemorySpanExporter;
import io.opentelemetry.sdk.trace.SdkTracerProvider;
import io.opentelemetry.sdk.trace.data.SpanData;
import io.opentelemetry.sdk.trace.export.SimpleSpanProcessor;
import java.io.ByteArrayOutputStream;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.util.List;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.boot.web.servlet.FilterRegistrationBean;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Import;
import org.springframework.context.annotation.Primary;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.web.context.WebApplicationContext;

/** Tracing switched on with spans kept in memory. */
@SpringBootTest(properties = {"SHUTDOWN_DRAIN_SECONDS=0", "LOG_LEVEL=info"})
@Import(TracingTest.TestTracing.class)
class TracingTest {

    static final String TRACE_ID = "4bf92f3577b34da6a3ce929d0e0e4736";
    static final String PARENT_SPAN_ID = "00f067aa0ba902b7";
    static final String TRACEPARENT = "00-" + TRACE_ID + "-" + PARENT_SPAN_ID + "-01";

    static final InMemorySpanExporter EXPORTER = InMemorySpanExporter.create();
    static final ByteArrayOutputStream LOG = new ByteArrayOutputStream();

    @TestConfiguration
    static class TestTracing {
        @Bean
        @Primary
        Tracing memoryTracing() {
            return Tracing.of(SdkTracerProvider.builder().addSpanProcessor(SimpleSpanProcessor.create(EXPORTER)).build());
        }

        @Bean
        @Primary
        JsonLog memoryLog() {
            return new JsonLog("payments", "info", new PrintStream(LOG, true, StandardCharsets.UTF_8));
        }
    }

    @Autowired WebApplicationContext context;
    @Autowired FilterRegistrationBean<ObservabilityFilter> filter;

    MockMvc mvc;

    @BeforeEach
    void setUp() {
        EXPORTER.reset();
        LOG.reset();
        mvc = ApiTestSupport.mockMvc(context, filter);
    }

    private static SpanData only(List<SpanData> spans, SpanKind kind) {
        List<SpanData> matching = spans.stream().filter(s -> s.getKind() == kind).toList();
        assertThat(matching).hasSize(1);
        return matching.get(0);
    }

    private String log() {
        return LOG.toString(StandardCharsets.UTF_8);
    }

    @Test
    void aRequestProducesAServerSpanNamedAfterTheRouteAndContinuingTheIncomingTrace() throws Exception {
        mvc.perform(post("/payments/authorize")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(BODY)
                        .header("Idempotency-Key", "k-trace-1")
                        .header("traceparent", TRACEPARENT))
                .andExpect(status().isCreated());

        SpanData server = only(EXPORTER.getFinishedSpanItems(), SpanKind.SERVER);
        assertThat(server.getName()).isEqualTo("POST /payments/authorize");
        assertThat(server.getTraceId()).isEqualTo(TRACE_ID);
        assertThat(server.getParentSpanId()).isEqualTo(PARENT_SPAN_ID);
        assertThat(server.getParentSpanContext().isRemote()).isTrue();
        assertThat(server.getAttributes().get(AttributeKey.stringKey("http.route"))).isEqualTo("/payments/authorize");
        assertThat(server.getAttributes().get(AttributeKey.stringKey("http.request.method"))).isEqualTo("POST");
        assertThat(server.getAttributes().get(AttributeKey.longKey("http.response.status_code"))).isEqualTo(201L);
        assertThat(server.getStatus().getStatusCode()).isNotEqualTo(StatusCode.ERROR);
    }

    @Test
    void theDecisionHasItsOwnSpanWithOnlyFixedWords() throws Exception {
        mvc.perform(post("/payments/authorize")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(BODY)
                        .header("Idempotency-Key", "k-trace-2"))
                .andExpect(status().isCreated());

        List<SpanData> spans = EXPORTER.getFinishedSpanItems();
        SpanData server = only(spans, SpanKind.SERVER);
        SpanData decide = only(spans, SpanKind.INTERNAL);
        assertThat(decide.getName()).isEqualTo("payments.decide");
        assertThat(decide.getParentSpanId()).isEqualTo(server.getSpanId());
        assertThat(decide.getAttributes().get(AttributeKey.stringKey("payments.decision"))).isEqualTo("approved");
        assertThat(decide.getAttributes().asMap()).hasSize(1);

        // A replay of the same key makes no decision.
        EXPORTER.reset();
        mvc.perform(post("/payments/authorize")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(BODY)
                        .header("Idempotency-Key", "k-trace-2"))
                .andExpect(status().isOk());
        assertThat(EXPORTER.getFinishedSpanItems()).extracting(SpanData::getKind).containsExactly(SpanKind.SERVER);
    }

    @Test
    void theLogTraceIdIsTheSpansTraceId() throws Exception {
        mvc.perform(post("/payments/authorize")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(BODY)
                        .header("Idempotency-Key", "k-trace-3"))
                .andExpect(status().isCreated());

        SpanData server = only(EXPORTER.getFinishedSpanItems(), SpanKind.SERVER);
        assertThat(server.getTraceId()).matches("[0-9a-f]{32}");
        assertThat(log()).contains("\"trace_id\":\"" + server.getTraceId() + "\"").contains("\"message\":\"request\"");
    }

    @Test
    void healthReadinessAndMetricsEndpointsCreateNoSpans() throws Exception {
        for (String path : List.of("/healthz", "/readyz", "/metrics", "/version")) {
            mvc.perform(get(path));
        }
        assertThat(EXPORTER.getFinishedSpanItems()).isEmpty();
        // Their log lines still carry a trace ID, from the header or a new one, as before.
        assertThat(log()).contains("\"route\":\"/healthz\"").contains("\"trace_id\":\"");
    }

    @Test
    void anUnmatchedPathIsNamedWithoutItsPath() throws Exception {
        mvc.perform(get("/no/such/place/12345"));
        SpanData server = only(EXPORTER.getFinishedSpanItems(), SpanKind.SERVER);
        assertThat(server.getName()).doesNotContain("12345");
    }

    @Test
    void aLookupSpanIsNamedByTheRouteTemplateNotTheId() throws Exception {
        mvc.perform(get("/payments/2c7fd4a7-0000-4000-8000-000000000000"));
        SpanData server = only(EXPORTER.getFinishedSpanItems(), SpanKind.SERVER);
        assertThat(server.getName()).isEqualTo("GET /payments/{id}");
    }
}
