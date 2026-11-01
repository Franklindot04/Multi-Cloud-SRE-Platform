package dev.mcsre.payments.obs;

import dev.mcsre.payments.config.AppConfig;
import io.opentelemetry.api.common.AttributeKey;
import io.opentelemetry.api.trace.Span;
import io.opentelemetry.api.trace.SpanContext;
import io.opentelemetry.api.trace.SpanKind;
import io.opentelemetry.api.trace.StatusCode;
import io.opentelemetry.context.Context;
import io.opentelemetry.context.Scope;
import io.opentelemetry.context.propagation.TextMapGetter;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ReadListener;
import jakarta.servlet.ServletException;
import jakarta.servlet.ServletInputStream;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletRequestWrapper;
import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.ThreadLocalRandom;
import java.util.regex.Pattern;
import org.springframework.http.server.PathContainer;
import org.springframework.web.filter.OncePerRequestFilter;
import org.springframework.web.servlet.HandlerMapping;
import org.springframework.web.util.pattern.PathPattern;
import org.springframework.web.util.pattern.PathPatternParser;

/**
 * Request IDs, trace propagation, body size limit, fault injection, Prometheus metrics and one
 * structured log line per request.
 */
public final class ObservabilityFilter extends OncePerRequestFilter {

    /** Thrown when a request body is larger than the configured limit. */
    public static final class PayloadTooLargeException extends RuntimeException {
        public PayloadTooLargeException() {
            super("request body is too large");
        }
    }

    /** Request attribute holding the trace of the current request. */
    public static final String TRACE_ATTRIBUTE = ObservabilityFilter.class.getName() + ".trace";

    private static final Pattern REQUEST_ID = Pattern.compile("^[A-Za-z0-9._-]{1,128}$");
    private static final Set<String> OPERATIONAL = Set.of("/healthz", "/readyz", "/metrics", "/version");
    private static final List<PathPattern> KNOWN_ROUTES = parseRoutes(
            "/payments/authorize", "/payments/{id}", "/healthz", "/readyz", "/metrics");

    private static final TextMapGetter<HttpServletRequest> HEADERS = new TextMapGetter<>() {
        @Override
        public Iterable<String> keys(HttpServletRequest request) {
            return Collections.list(request.getHeaderNames());
        }

        @Override
        public String get(HttpServletRequest request, String key) {
            return request == null ? null : request.getHeader(key);
        }
    };

    private final String service;
    private final AppConfig config;
    private final HttpMetrics metrics;
    private final JsonLog log;
    private final Tracing tracing;

    public ObservabilityFilter(String service, AppConfig config, HttpMetrics metrics, JsonLog log) {
        this(service, config, metrics, log, Tracing.off());
    }

    public ObservabilityFilter(String service, AppConfig config, HttpMetrics metrics, JsonLog log, Tracing tracing) {
        this.service = service;
        this.config = config;
        this.metrics = metrics;
        this.log = log;
        this.tracing = tracing;
    }

    private static List<PathPattern> parseRoutes(String... patterns) {
        PathPatternParser parser = new PathPatternParser();
        return Arrays.stream(patterns).map(parser::parse).toList();
    }

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain chain)
            throws ServletException, IOException {
        long start = System.nanoTime();

        String requestId = request.getHeader("X-Request-Id");
        if (requestId == null || !REQUEST_ID.matcher(requestId).matches()) {
            requestId = UUID.randomUUID().toString();
        }
        TraceContext header = TraceContext.fromHeader(request.getHeader("traceparent"));
        // The server span continues the incoming trace. There is none for the operational endpoints or when tracing is off.
        Span span = null;
        Scope scope = null;
        if (tracing.isEnabled() && !OPERATIONAL.contains(request.getRequestURI())) {
            Context parent = tracing.propagators().getTextMapPropagator().extract(Context.root(), request, HEADERS);
            span = tracing.tracer().spanBuilder(request.getMethod())
                    .setParent(parent)
                    .setSpanKind(SpanKind.SERVER)
                    .setAttribute(AttributeKey.stringKey("http.request.method"), request.getMethod())
                    .setAttribute(AttributeKey.stringKey("url.scheme"), request.getScheme())
                    .startSpan();
            scope = span.makeCurrent();
        }
        // The trace ID of the log lines is the span's; without a span it is the one in the traceparent header, as before.
        SpanContext spanContext = Span.current().getSpanContext();
        TraceContext trace = spanContext.isValid() ? header.withTraceId(spanContext.getTraceId()) : header;
        request.setAttribute(TRACE_ATTRIBUTE, trace);
        request.setAttribute(RequestIds.ATTRIBUTE, requestId);
        response.setHeader("X-Request-Id", requestId);
        RequestScope.enter(requestId, trace.traceId());

        metrics.started();
        try {
            long declared = request.getContentLengthLong();
            if (declared > config.maxBodyBytes()) {
                reject(response, requestId, 413, "payload_too_large", "request body is too large");
            } else if (!injectFault(request, response, requestId)) {
                chain.doFilter(new LimitedRequest(request, config.maxBodyBytes()), response);
            }
        } catch (RuntimeException | IOException | ServletException e) {
            Map<String, Object> fields = new LinkedHashMap<>();
            fields.put("request_id", requestId);
            fields.put("error", e.getClass().getSimpleName());
            fields.put("detail", String.valueOf(e.getMessage()));
            log.error("unhandled error", fields);
            Tracing.recordFailure(e);
            if (!response.isCommitted()) {
                reject(response, requestId, 500, "internal_error", "internal error");
            }
        } finally {
            RequestScope.leave();
            double seconds = (System.nanoTime() - start) / 1_000_000_000.0;
            String route = routeOf(request);
            int status = response.getStatus();
            metrics.finished(request.getMethod(), route, status, seconds);
            if (span != null) {
                span.updateName(request.getMethod() + " " + route);
                span.setAttribute(AttributeKey.stringKey("http.route"), route);
                span.setAttribute(AttributeKey.longKey("http.response.status_code"), (long) status);
                if (status >= 500) {
                    span.setStatus(StatusCode.ERROR, "server error");
                }
                scope.close();
                span.end();
            }

            Map<String, Object> fields = new LinkedHashMap<>();
            fields.put("request_id", requestId);
            fields.put("trace_id", trace.traceId());
            fields.put("method", request.getMethod());
            fields.put("route", route);
            fields.put("status", status);
            fields.put("duration_ms", Math.round(seconds * 1_000_000.0) / 1000.0);
            log.info("request", fields);
        }
    }

    /** Returns true when the fault answered the request. Never applies to operational endpoints. */
    private boolean injectFault(HttpServletRequest request, HttpServletResponse response, String requestId) throws IOException {
        if (!config.faultEnabled() || OPERATIONAL.contains(request.getRequestURI())) {
            return false;
        }
        if (config.faultLatencyMs() > 0) {
            try {
                Thread.sleep(config.faultLatencyMs());
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
        }
        if (config.faultErrorRate() > 0 && ThreadLocalRandom.current().nextDouble() < config.faultErrorRate()) {
            reject(response, requestId, 503, "fault_injected", "failure injected for testing");
            return true;
        }
        return false;
    }

    private static void reject(HttpServletResponse response, String requestId, int status, String code, String message)
            throws IOException {
        response.setStatus(status);
        response.setContentType("application/json");
        response.setCharacterEncoding(StandardCharsets.UTF_8.name());
        response.getWriter().write(ErrorJson.of(code, message, requestId));
    }

    /** The route template, never the raw path, to keep label cardinality bounded. */
    private static String routeOf(HttpServletRequest request) {
        Object matched = request.getAttribute(HandlerMapping.BEST_MATCHING_PATTERN_ATTRIBUTE);
        // "/**" is Spring's catch-all resource handler: a request nothing else matched.
        if (matched instanceof String s && !s.endsWith("/**")) {
            return s;
        }
        PathContainer path = PathContainer.parsePath(request.getRequestURI());
        for (PathPattern pattern : KNOWN_ROUTES) {
            if (pattern.matches(path)) {
                return pattern.getPatternString();
            }
        }
        return "unmatched";
    }

    private static final class LimitedRequest extends HttpServletRequestWrapper {
        private final long limit;
        private ServletInputStream stream;

        LimitedRequest(HttpServletRequest request, long limit) {
            super(request);
            this.limit = limit;
        }

        @Override
        public ServletInputStream getInputStream() throws IOException {
            if (stream == null) {
                stream = new CountingStream(super.getInputStream(), limit);
            }
            return stream;
        }
    }

    private static final class CountingStream extends ServletInputStream {
        private final ServletInputStream delegate;
        private final long limit;
        private long count;

        CountingStream(ServletInputStream delegate, long limit) {
            this.delegate = delegate;
            this.limit = limit;
        }

        private void add(long n) {
            if (n > 0) {
                count += n;
                if (count > limit) {
                    throw new PayloadTooLargeException();
                }
            }
        }

        @Override
        public int read() throws IOException {
            int b = delegate.read();
            add(b >= 0 ? 1 : 0);
            return b;
        }

        @Override
        public int read(byte[] b, int off, int len) throws IOException {
            int n = delegate.read(b, off, len);
            add(n);
            return n;
        }

        @Override
        public boolean isFinished() {
            return delegate.isFinished();
        }

        @Override
        public boolean isReady() {
            return delegate.isReady();
        }

        @Override
        public void setReadListener(ReadListener listener) {
            delegate.setReadListener(listener);
        }
    }
}
