package dev.mcsre.payments.obs;

import io.opentelemetry.api.common.AttributeKey;
import io.opentelemetry.api.common.Attributes;
import io.opentelemetry.api.trace.Span;
import io.opentelemetry.api.trace.Tracer;
import io.opentelemetry.api.trace.TracerProvider;
import io.opentelemetry.context.propagation.ContextPropagators;
import io.opentelemetry.context.propagation.TextMapPropagator;
import io.opentelemetry.api.baggage.propagation.W3CBaggagePropagator;
import io.opentelemetry.api.trace.propagation.W3CTraceContextPropagator;
import io.opentelemetry.sdk.autoconfigure.AutoConfiguredOpenTelemetrySdk;
import io.opentelemetry.sdk.resources.Resource;
import io.opentelemetry.sdk.trace.SdkTracerProvider;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;
import java.util.function.Function;

/**
 * OpenTelemetry tracing, configured only through the standard OTEL_* environment variables.
 *
 * <p>Tracing is off unless OTEL_EXPORTER_OTLP_ENDPOINT or OTEL_EXPORTER_OTLP_TRACES_ENDPOINT is set, so local runs, tests
 * and CI need no Collector. OTEL_SDK_DISABLED=true and OTEL_TRACES_EXPORTER=none turn it off even when an endpoint is
 * set. The SDK reads the rest itself: the OTLP/gRPC exporter (an endpoint that starts with http:// is a plain
 * connection, https:// uses TLS), the sampler (OTEL_TRACES_SAMPLER and OTEL_TRACES_SAMPLER_ARG; parent-based, every trace,
 * when they are not set), OTEL_SERVICE_NAME and OTEL_RESOURCE_ATTRIBUTES.
 *
 * <p>Nothing here can fail a request or the process: a setup problem turns tracing off, the exporter runs in the
 * background and drops spans it cannot deliver, and {@link #close()} gives up after a short time.
 */
public final class Tracing implements AutoCloseable {

    /** How long shutdown waits for spans that are still queued. */
    public static final long FLUSH_TIMEOUT_SECONDS = 5;

    private static final String TRACER_NAME = "dev.mcsre.payments";
    private static final AttributeKey<String> EXCEPTION_TYPE = AttributeKey.stringKey("exception.type");
    private static final ContextPropagators PROPAGATORS = ContextPropagators.create(
            TextMapPropagator.composite(W3CTraceContextPropagator.getInstance(), W3CBaggagePropagator.getInstance()));

    private final SdkTracerProvider provider;
    private final Resource resource;

    private Tracing(SdkTracerProvider provider, Resource resource) {
        this.provider = provider;
        this.resource = resource;
    }

    /** Tracing that is off: spans are never recorded and nothing is exported. */
    public static Tracing off() {
        return new Tracing(null, Resource.empty());
    }

    /** Tracing on a given provider, for tests that keep the spans in memory. */
    public static Tracing of(SdkTracerProvider provider) {
        return new Tracing(provider, Resource.empty());
    }

    /** True when the environment asks for traces to be exported. */
    public static boolean enabled(Function<String, String> env) {
        if ("true".equalsIgnoreCase(value(env, "OTEL_SDK_DISABLED")) || "none".equalsIgnoreCase(value(env, "OTEL_TRACES_EXPORTER"))) {
            return false;
        }
        return !value(env, "OTEL_EXPORTER_OTLP_ENDPOINT").isEmpty() || !value(env, "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT").isEmpty();
    }

    /**
     * Builds the tracing setup from the environment, or tracing that is off. Never throws. The exporter connects in the
     * background, so an unreachable Collector costs spans, not requests. {@code properties} are defaults in the SDK's
     * property form (otel.exporter.otlp.endpoint, ...); the environment variables take precedence over them.
     */
    public static Tracing create(Function<String, String> env, Map<String, String> properties, String service, String version, JsonLog log) {
        if (!enabled(env)) {
            return off();
        }
        try {
            Map<String, String> defaults = new HashMap<>(properties);
            defaults.putIfAbsent("otel.service.name", service);
            // Only traces are exported; the SDK would otherwise set up metric and log exporters as well.
            defaults.put("otel.metrics.exporter", "none");
            defaults.put("otel.logs.exporter", "none");
            AtomicReference<Resource> built = new AtomicReference<>(Resource.empty());
            AutoConfiguredOpenTelemetrySdk sdk = AutoConfiguredOpenTelemetrySdk.builder()
                    .addPropertiesSupplier(() -> defaults)
                    .addResourceCustomizer((resource, config) -> {
                        Resource complete = withVersion(resource, version);
                        built.set(complete);
                        return complete;
                    })
                    .disableShutdownHook()
                    .build();
            return new Tracing(sdk.getOpenTelemetrySdk().getSdkTracerProvider(), built.get());
        } catch (RuntimeException e) {
            log.warn("tracing is disabled", Map.of("error", e.getClass().getSimpleName()));
            return off();
        }
    }

    private static Resource withVersion(Resource resource, String version) {
        if (version == null || version.isBlank() || resource.getAttribute(AttributeKey.stringKey("service.version")) != null) {
            return resource;
        }
        return resource.merge(Resource.create(Attributes.of(AttributeKey.stringKey("service.version"), version)));
    }

    private static String value(Function<String, String> env, String key) {
        String v = env.apply(key);
        return v == null ? "" : v.trim();
    }

    /** The resource of the spans: service.name, service.version and whatever OTEL_RESOURCE_ATTRIBUTES adds. */
    public Resource resource() {
        return resource;
    }

    public boolean isEnabled() {
        return provider != null;
    }

    public Tracer tracer() {
        return (provider == null ? TracerProvider.noop() : provider).get(TRACER_NAME);
    }

    public ContextPropagators propagators() {
        return PROPAGATORS;
    }

    /**
     * Records a failure on the current span as an event with only the type of the exception, never its message. The
     * server span gets its error status from the 5xx response.
     */
    public static void recordFailure(Throwable error) {
        Span.current().addEvent("exception", Attributes.of(EXCEPTION_TYPE, error.getClass().getSimpleName()));
    }

    /** Flushes the queued spans and stops the exporter, waiting at most {@link #FLUSH_TIMEOUT_SECONDS} seconds. */
    @Override
    public void close() {
        if (provider != null) {
            provider.shutdown().join(FLUSH_TIMEOUT_SECONDS, TimeUnit.SECONDS);
        }
    }
}
