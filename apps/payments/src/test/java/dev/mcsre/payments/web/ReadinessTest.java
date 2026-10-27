package dev.mcsre.payments.web;

import static org.assertj.core.api.Assertions.assertThat;

import dev.mcsre.payments.domain.InMemoryPaymentRepository;
import dev.mcsre.payments.domain.Payment;
import dev.mcsre.payments.domain.PaymentRepository;
import dev.mcsre.payments.obs.Drain;
import io.prometheus.metrics.model.registry.PrometheusRegistry;
import java.sql.SQLException;
import java.util.Map;
import java.util.Optional;
import java.util.function.Supplier;
import org.junit.jupiter.api.Test;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;

class ReadinessTest {

    /** A repository whose database is down. */
    private static final class DownRepository implements PaymentRepository {
        @Override
        public Stored saveIfAbsent(String key, String fingerprint, Supplier<Payment> create) {
            throw new IllegalStateException("not used");
        }

        @Override
        public Optional<Payment> findById(String id) {
            return Optional.empty();
        }

        @Override
        public void ready() throws SQLException {
            throw new SQLException("connection refused");
        }
    }

    private static ResponseEntity<Map<String, String>> readyz(PaymentRepository repository, Drain drain) {
        return new OpsController(drain, new PrometheusRegistry(), repository).readyz();
    }

    @Test
    void readyWhenTheStorageIsUp() {
        assertThat(readyz(new InMemoryPaymentRepository(10), new Drain()).getStatusCode()).isEqualTo(HttpStatus.OK);
    }

    @Test
    void notReadyWhenTheDatabaseIsDown() {
        ResponseEntity<Map<String, String>> response = readyz(new DownRepository(), new Drain());
        assertThat(response.getStatusCode()).isEqualTo(HttpStatus.SERVICE_UNAVAILABLE);
        assertThat(response.getBody()).containsEntry("status", "not_ready").containsEntry("database", "fail: SQLException");
    }

    @Test
    void drainingWinsAndHealthzIsNotAffected() {
        Drain drain = new Drain();
        drain.start();
        assertThat(readyz(new InMemoryPaymentRepository(10), drain).getBody()).containsEntry("status", "draining");
        OpsController ops = new OpsController(drain, new PrometheusRegistry(), new DownRepository());
        assertThat(ops.healthz()).containsEntry("status", "ok");
    }
}
