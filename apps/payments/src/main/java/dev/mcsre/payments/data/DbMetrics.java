package dev.mcsre.payments.data;

import com.zaxxer.hikari.HikariDataSource;
import com.zaxxer.hikari.HikariPoolMXBean;
import io.prometheus.metrics.core.metrics.GaugeWithCallback;
import io.prometheus.metrics.core.metrics.Histogram;
import io.prometheus.metrics.model.registry.PrometheusRegistry;

/** Pool state and query latency, under the same names the other services use. */
public final class DbMetrics {

    private static final double[] BUCKETS = {0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5};

    private final Histogram duration;

    public DbMetrics(PrometheusRegistry registry) {
        this.duration = Histogram.builder()
                .name("db_query_duration_seconds")
                .help("Database query latency in seconds.")
                .labelNames("operation")
                .classicOnly()
                .classicUpperBounds(BUCKETS)
                .register(registry);
    }

    /** Registers db_pool_connections{state} read straight from the pool when scraped. */
    public static void bindPool(HikariDataSource pool, PrometheusRegistry registry) {
        GaugeWithCallback.builder()
                .name("db_pool_connections")
                .help("Database pool connections by state.")
                .labelNames("state")
                .callback(callback -> {
                    HikariPoolMXBean bean = pool.getHikariPoolMXBean();
                    callback.call(bean == null ? 0 : bean.getIdleConnections(), "idle");
                    callback.call(bean == null ? 0 : bean.getActiveConnections(), "in_use");
                    callback.call(pool.getMaximumPoolSize(), "max");
                })
                .register(registry);
    }

    public void observe(String operation, long nanos) {
        duration.labelValues(operation).observe(nanos / 1_000_000_000.0);
    }
}
