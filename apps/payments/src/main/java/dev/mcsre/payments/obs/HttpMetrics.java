package dev.mcsre.payments.obs;

import io.prometheus.metrics.core.metrics.Counter;
import io.prometheus.metrics.core.metrics.Gauge;
import io.prometheus.metrics.core.metrics.Histogram;
import io.prometheus.metrics.model.registry.PrometheusRegistry;

/** The HTTP metrics every service exposes under the same names. */
public final class HttpMetrics {

    /** Shared by every service so latency can be compared across them. */
    static final double[] BUCKETS = {0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10};

    private final String service;
    private final Counter requests;
    private final Histogram duration;
    private final Gauge inFlight;

    public HttpMetrics(String service, PrometheusRegistry registry) {
        this.service = service;
        this.requests = Counter.builder()
                .name("http_requests_total")
                .help("Total HTTP requests handled.")
                .labelNames("service", "method", "route", "status")
                .register(registry);
        this.duration = Histogram.builder()
                .name("http_request_duration_seconds")
                .help("HTTP request latency in seconds.")
                .labelNames("service", "method", "route")
                .classicOnly()
                .classicUpperBounds(BUCKETS)
                .register(registry);
        this.inFlight = Gauge.builder()
                .name("http_requests_in_flight")
                .help("HTTP requests currently being handled.")
                .labelNames("service")
                .register(registry);
    }

    public void started() {
        inFlight.labelValues(service).inc();
    }

    public void finished(String method, String route, int status, double seconds) {
        inFlight.labelValues(service).dec();
        requests.labelValues(service, method, route, Integer.toString(status)).inc();
        duration.labelValues(service, method, route).observe(seconds);
    }
}
