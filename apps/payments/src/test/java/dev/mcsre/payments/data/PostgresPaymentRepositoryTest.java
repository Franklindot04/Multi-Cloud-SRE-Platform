package dev.mcsre.payments.data;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import com.zaxxer.hikari.HikariDataSource;
import dev.mcsre.payments.config.AppConfig;
import dev.mcsre.payments.domain.Payment;
import dev.mcsre.payments.domain.PaymentRepository;
import dev.mcsre.payments.obs.JsonLog;
import io.prometheus.metrics.model.registry.PrometheusRegistry;
import java.io.ByteArrayOutputStream;
import java.io.PrintStream;
import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.Callable;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;

/**
 * Runs against a real PostgreSQL: set INTEGRATION=1 and the DB_* variables (the integration stack
 * does this). Skipped otherwise, so the plain unit-test run needs no database.
 */
@EnabledIfEnvironmentVariable(named = "INTEGRATION", matches = "1")
class PostgresPaymentRepositoryTest {

    private static AppConfig.Db db;
    private static HikariDataSource pool;
    private static PostgresPaymentRepository repository;

    @BeforeAll
    static void connect() {
        db = AppConfig.load(name -> "STORAGE".equals(name) ? "postgres" : System.getenv(name)).db();
        Database.migrate(db);
        PrometheusRegistry registry = new PrometheusRegistry();
        pool = Database.pool(db);
        repository = new PostgresPaymentRepository(pool, new DbMetrics(registry), new JsonLog("test", "warn", new PrintStream(new ByteArrayOutputStream())));
    }

    @AfterAll
    static void close() {
        pool.close();
    }

    private static Payment payment(String orderId, long amount) {
        return new Payment(UUID.randomUUID().toString(), orderId, amount, "USD", Payment.Status.APPROVED, null, Instant.now());
    }

    private static String key() {
        return "it-" + UUID.randomUUID();
    }

    @Test
    void migrationsApplyCleanlyASecondTime() {
        var again = Database.migrate(db);
        assertThat(again.migrationsExecuted).isZero();
        assertThat(again.success).isTrue();
    }

    @Test
    void storesAndReplaysByKey() throws Exception {
        String key = key();
        Payment first = payment("order-a", 2500);
        PaymentRepository.Stored stored = repository.saveIfAbsent(key, "fp", () -> first);
        assertThat(stored.created()).isTrue();
        PaymentRepository.Stored replay = repository.saveIfAbsent(key, "fp", () -> payment("order-a", 2500));
        assertThat(replay.created()).isFalse();
        assertThat(replay.payment().id()).isEqualTo(first.id());
        assertThat(repository.findById(first.id())).isPresent();
        repository.ready();
    }

    @Test
    void aKeyWithAnotherRequestIsAMismatch() {
        String key = key();
        repository.saveIfAbsent(key, "fp-1", () -> payment("order-b", 100));
        assertThatThrownBy(() -> repository.saveIfAbsent(key, "fp-2", () -> payment("order-b", 200)))
                .isInstanceOf(PaymentRepository.KeyMismatchException.class);
    }

    @Test
    void anUnknownOrMalformedIdIsEmpty() {
        assertThat(repository.findById(UUID.randomUUID().toString())).isEmpty();
        assertThat(repository.findById("not-a-uuid")).isEmpty();
    }

    @Test
    void manyParallelRequestsWithOneKeyCreateExactlyOnePayment() throws Exception {
        String key = key();
        int threads = 32;
        CountDownLatch start = new CountDownLatch(1);
        ExecutorService executor = Executors.newFixedThreadPool(threads);
        try {
            List<Future<PaymentRepository.Stored>> futures = new ArrayList<>();
            for (int i = 0; i < threads; i++) {
                Callable<PaymentRepository.Stored> task = () -> {
                    start.await();
                    return repository.saveIfAbsent(key, "fp", () -> payment("order-race", 999));
                };
                futures.add(executor.submit(task));
            }
            start.countDown();
            List<PaymentRepository.Stored> results = new ArrayList<>();
            for (Future<PaymentRepository.Stored> future : futures) {
                results.add(future.get());
            }
            assertThat(results.stream().filter(PaymentRepository.Stored::created)).hasSize(1);
            assertThat(results.stream().map(r -> r.payment().id()).distinct()).hasSize(1);
        } finally {
            executor.shutdownNow();
        }
        try (var connection = pool.getConnection();
                var statement = connection.prepareStatement("SELECT count(*) FROM payments WHERE idempotency_key = ?")) {
            statement.setString(1, key);
            try (var rows = statement.executeQuery()) {
                rows.next();
                assertThat(rows.getInt(1)).isEqualTo(1);
            }
        }
    }

    @Test
    void aDatabaseFailureIsReportedAsUnavailable() {
        AppConfig.Db unreachable = new AppConfig.Db("127.0.0.1", 1, db.name(), db.user(), db.password(), 1, 500, 1000);
        try (HikariDataSource broken = Database.pool(unreachable)) {
            PostgresPaymentRepository repo = new PostgresPaymentRepository(
                    broken, new DbMetrics(new PrometheusRegistry()), new JsonLog("test", "error", new PrintStream(new ByteArrayOutputStream())));
            assertThatThrownBy(() -> repo.saveIfAbsent(key(), "fp", () -> payment("o", 1)))
                    .isInstanceOf(StorageUnavailableException.class);
            assertThatThrownBy(repo::ready).isInstanceOf(Exception.class);
        }
    }
}
