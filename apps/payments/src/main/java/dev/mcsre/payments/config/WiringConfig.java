package dev.mcsre.payments.config;

import com.zaxxer.hikari.HikariDataSource;
import dev.mcsre.payments.data.Database;
import dev.mcsre.payments.data.DbMetrics;
import dev.mcsre.payments.data.PostgresPaymentRepository;
import dev.mcsre.payments.domain.AuthorizationService;
import dev.mcsre.payments.domain.DecisionPolicy;
import dev.mcsre.payments.domain.InMemoryPaymentRepository;
import dev.mcsre.payments.domain.PaymentRepository;
import dev.mcsre.payments.obs.Drain;
import dev.mcsre.payments.obs.HttpMetrics;
import dev.mcsre.payments.obs.JsonLog;
import dev.mcsre.payments.obs.ObservabilityFilter;
import dev.mcsre.payments.obs.Tracing;
import io.prometheus.metrics.model.registry.PrometheusRegistry;
import java.time.Clock;
import java.util.Map;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.boot.web.servlet.FilterRegistrationBean;
import org.springframework.context.SmartLifecycle;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.Ordered;
import org.springframework.core.env.Environment;

/** Wires the application together. */
@Configuration
public class WiringConfig {

    static final String SERVICE = "payments";

    @Bean
    AppConfig appConfig(Environment environment) {
        return AppConfig.load(environment::getProperty);
    }

    @Bean
    PrometheusRegistry prometheusRegistry() {
        return new PrometheusRegistry();
    }

    @Bean
    Drain drain() {
        return new Drain();
    }

    @Bean
    JsonLog jsonLog(AppConfig config) {
        return new JsonLog(SERVICE, config.logLevel(), System.out);
    }

    /**
     * Tracing is off unless OTEL_EXPORTER_OTLP_ENDPOINT is set. Closing it on shutdown flushes the queued spans, for at
     * most a few seconds, after the web server has stopped.
     */
    @Bean(destroyMethod = "close")
    Tracing tracing(Environment environment, JsonLog log) {
        return Tracing.create(environment::getProperty, Map.of(), SERVICE, environment.getProperty("APP_VERSION"), log);
    }

    @Bean(destroyMethod = "close")
    @ConditionalOnProperty(name = "STORAGE", havingValue = "postgres")
    HikariDataSource dataSource(AppConfig config, PrometheusRegistry registry) {
        HikariDataSource pool = Database.pool(config.db());
        DbMetrics.bindPool(pool, registry);
        return pool;
    }

    @Bean
    @ConditionalOnProperty(name = "STORAGE", havingValue = "postgres")
    PaymentRepository postgresPaymentRepository(
            HikariDataSource dataSource, PrometheusRegistry registry, JsonLog log, Tracing tracing) {
        return new PostgresPaymentRepository(dataSource, new DbMetrics(registry), log, tracing);
    }

    @Bean
    @ConditionalOnProperty(name = "STORAGE", havingValue = "memory", matchIfMissing = true)
    PaymentRepository inMemoryPaymentRepository(AppConfig config) {
        return new InMemoryPaymentRepository(config.maxPayments());
    }

    @Bean
    AuthorizationService authorizationService(PaymentRepository repository, AppConfig config, Tracing tracing) {
        DecisionPolicy policy = new DecisionPolicy(config.declineAboveMinor(), config.approvalRatio(), config.allowedCurrencies());
        return new AuthorizationService(repository, policy, Clock.systemUTC(), tracing.tracer());
    }

    @Bean
    FilterRegistrationBean<ObservabilityFilter> observabilityFilter(
            AppConfig config, PrometheusRegistry registry, JsonLog log, Tracing tracing) {
        FilterRegistrationBean<ObservabilityFilter> bean =
                new FilterRegistrationBean<>(new ObservabilityFilter(SERVICE, config, new HttpMetrics(SERVICE, registry), log, tracing));
        bean.setOrder(Ordered.HIGHEST_PRECEDENCE + 10);
        return bean;
    }

    /** Logs the fault injection state at startup so it is never enabled silently. */
    @Bean
    SmartLifecycle startupBanner(AppConfig config, JsonLog log) {
        return new SimpleLifecycle(Integer.MAX_VALUE - 4096, () -> {
            if (config.faultEnabled()) {
                log.warn("fault injection is ENABLED",
                        Map.of("latency_ms", config.faultLatencyMs(), "error_rate", config.faultErrorRate()));
            }
            log.info("listening", Map.of("port", config.port()));
        }, () -> { });
    }

    /**
     * On shutdown, fail /readyz first and wait for the drain period before the web server stops
     * accepting connections (which happens at a lower phase).
     */
    @Bean
    SmartLifecycle drainOnShutdown(Drain drain, AppConfig config, JsonLog log) {
        return new SimpleLifecycle(Integer.MAX_VALUE, () -> { }, () -> {
            log.info("shutdown requested", Map.of("drain_seconds", config.drainSeconds()));
            drain.start();
            try {
                Thread.sleep(config.drainSeconds() * 1000L);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
        });
    }

    private static final class SimpleLifecycle implements SmartLifecycle {
        private final int phase;
        private final Runnable onStart;
        private final Runnable onStop;
        private volatile boolean running;

        SimpleLifecycle(int phase, Runnable onStart, Runnable onStop) {
            this.phase = phase;
            this.onStart = onStart;
            this.onStop = onStop;
        }

        @Override
        public void start() {
            onStart.run();
            running = true;
        }

        @Override
        public void stop() {
            running = false;
            onStop.run();
        }

        @Override
        public boolean isRunning() {
            return running;
        }

        @Override
        public int getPhase() {
            return phase;
        }
    }
}
