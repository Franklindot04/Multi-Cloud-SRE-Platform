package dev.mcsre.payments.obs;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatCode;

import dev.mcsre.payments.data.DbMetrics;
import dev.mcsre.payments.data.PostgresPaymentRepository;
import dev.mcsre.payments.data.StorageUnavailableException;
import io.opentelemetry.api.common.AttributeKey;
import io.opentelemetry.api.trace.Span;
import io.opentelemetry.api.trace.SpanKind;
import io.opentelemetry.api.trace.StatusCode;
import io.opentelemetry.context.Scope;
import io.opentelemetry.sdk.testing.exporter.InMemorySpanExporter;
import io.opentelemetry.sdk.trace.SdkTracerProvider;
import io.opentelemetry.sdk.trace.data.SpanData;
import io.opentelemetry.sdk.trace.export.SimpleSpanProcessor;
import io.prometheus.metrics.model.registry.PrometheusRegistry;
import java.io.ByteArrayOutputStream;
import java.io.PrintStream;
import java.lang.reflect.Proxy;
import java.nio.charset.StandardCharsets;
import java.sql.SQLException;
import java.time.Duration;
import java.util.Map;
import javax.sql.DataSource;
import org.junit.jupiter.api.Test;

class TracingSetupTest {

    private static final JsonLog QUIET = new JsonLog("payments", "error", new PrintStream(new ByteArrayOutputStream()));

    @Test
    void tracingIsOffWithoutAnEndpointAndNothingIsCreated() {
        Tracing tracing = Tracing.create(key -> null, Map.of(), "payments", "1.0.0", QUIET);

        assertThat(tracing.isEnabled()).isFalse();
        Span span = tracing.tracer().spanBuilder("x").startSpan();
        assertThat(span.getSpanContext().isValid()).isFalse();
        span.end();
        assertThatCode(tracing::close).doesNotThrowAnyException();
    }

    @Test
    void anEndpointTurnsItOnAndTheDisablingSettingsTurnItOff() {
        String endpoint = "http://collector:4317";
        assertThat(Tracing.enabled(Map.of("OTEL_EXPORTER_OTLP_ENDPOINT", endpoint)::get)).isTrue();
        assertThat(Tracing.enabled(Map.of("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT", endpoint)::get)).isTrue();
        assertThat(Tracing.enabled(Map.of("OTEL_EXPORTER_OTLP_ENDPOINT", " ")::get)).isFalse();
        assertThat(Tracing.enabled(Map.of("OTEL_EXPORTER_OTLP_ENDPOINT", endpoint, "OTEL_SDK_DISABLED", "true")::get)).isFalse();
        assertThat(Tracing.enabled(Map.of("OTEL_EXPORTER_OTLP_ENDPOINT", endpoint, "OTEL_TRACES_EXPORTER", "none")::get)).isFalse();
    }

    @Test
    void anUnreachableCollectorBlocksNeitherStartupSpansNorShutdown() {
        String endpoint = "http://127.0.0.1:1"; // nothing listens here
        Map<String, String> env = Map.of("OTEL_EXPORTER_OTLP_ENDPOINT", endpoint);
        Map<String, String> properties = Map.of("otel.exporter.otlp.endpoint", endpoint);

        org.junit.jupiter.api.Assertions.assertTimeout(Duration.ofSeconds(Tracing.FLUSH_TIMEOUT_SECONDS + 5), () -> {
            Tracing tracing = Tracing.create(env::get, properties, "payments", "1.0.0", QUIET);
            assertThat(tracing.isEnabled()).isTrue();
            Span span = tracing.tracer().spanBuilder("work").startSpan();
            span.end();
            tracing.close();
        });
    }

    @Test
    void theResourceHasServiceNameVersionAndNamespaceAndTheEnvironmentWins() {
        String endpoint = "http://127.0.0.1:1";
        Map<String, String> env = Map.of("OTEL_EXPORTER_OTLP_ENDPOINT", endpoint);
        Tracing tracing = Tracing.create(env::get,
                Map.of("otel.exporter.otlp.endpoint", endpoint, "otel.resource.attributes", "service.namespace=shop"),
                "payments", "1.2.3", QUIET);
        assertThat(tracing.resource().getAttribute(AttributeKey.stringKey("service.name"))).isEqualTo("payments");
        assertThat(tracing.resource().getAttribute(AttributeKey.stringKey("service.version"))).isEqualTo("1.2.3");
        assertThat(tracing.resource().getAttribute(AttributeKey.stringKey("service.namespace"))).isEqualTo("shop");
        tracing.close();

        Tracing renamed = Tracing.create(env::get,
                Map.of("otel.exporter.otlp.endpoint", endpoint, "otel.service.name", "renamed"), "payments", null, QUIET);
        assertThat(renamed.resource().getAttribute(AttributeKey.stringKey("service.name"))).isEqualTo("renamed");
        renamed.close();
    }

    @Test
    void aDatabaseSpanHasTheOperationAndNoSqlAndAFailureRecordsOnlyTheExceptionType() {
        InMemorySpanExporter exporter = InMemorySpanExporter.create();
        Tracing tracing = Tracing.of(SdkTracerProvider.builder().addSpanProcessor(SimpleSpanProcessor.create(exporter)).build());
        DataSource broken = (DataSource) Proxy.newProxyInstance(getClass().getClassLoader(), new Class<?>[] {DataSource.class},
                (proxy, method, args) -> {
                    throw new SQLException("password authentication failed for user payments, card 4111");
                });
        PostgresPaymentRepository repository = new PostgresPaymentRepository(broken, new DbMetrics(new PrometheusRegistry()), QUIET, tracing);

        try (Scope ignored = tracing.tracer().spanBuilder("parent").startSpan().makeCurrent()) {
            org.junit.jupiter.api.Assertions.assertThrows(StorageUnavailableException.class, () -> repository.findById("2c7fd4a7-0000-4000-8000-000000000000"));
        }

        SpanData db = exporter.getFinishedSpanItems().stream().filter(s -> s.getKind() == SpanKind.CLIENT).findFirst().orElseThrow();
        assertThat(db.getName()).isEqualTo("db get_payment");
        assertThat(db.getAttributes().asMap().keySet().stream().map(AttributeKey::getKey))
                .containsExactlyInAnyOrder("db.system.name", "db.operation.name");
        assertThat(db.getStatus().getStatusCode()).isEqualTo(StatusCode.ERROR);
        assertThat(db.getStatus().getDescription()).isEqualTo("database operation failed");
        assertThat(db.getEvents()).hasSize(1);
        assertThat(db.getEvents().get(0).getAttributes().size()).isEqualTo(1);
        assertThat(db.getEvents().get(0).getAttributes().get(AttributeKey.stringKey("exception.type"))).isEqualTo("SQLException");
    }

    @Test
    void logLinesWrittenInsideASpanCarryItsTraceIdAndOthersDoNot() {
        InMemorySpanExporter exporter = InMemorySpanExporter.create();
        Tracing tracing = Tracing.of(SdkTracerProvider.builder().addSpanProcessor(SimpleSpanProcessor.create(exporter)).build());
        ByteArrayOutputStream buffer = new ByteArrayOutputStream();
        JsonLog log = new JsonLog("payments", "info", new PrintStream(buffer, true, StandardCharsets.UTF_8));

        Span span = tracing.tracer().spanBuilder("work").startSpan();
        try (Scope ignored = span.makeCurrent()) {
            log.info("inside", Map.of());
        } finally {
            span.end();
        }
        log.info("outside", Map.of());

        String[] lines = buffer.toString(StandardCharsets.UTF_8).split("\n");
        assertThat(lines[0]).contains("\"trace_id\":\"" + span.getSpanContext().getTraceId() + "\"");
        assertThat(lines[1]).doesNotContain("trace_id");
    }
}
