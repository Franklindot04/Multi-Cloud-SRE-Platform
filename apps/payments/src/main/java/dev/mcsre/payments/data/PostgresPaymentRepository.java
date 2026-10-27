package dev.mcsre.payments.data;

import dev.mcsre.payments.domain.Payment;
import dev.mcsre.payments.domain.PaymentRepository;
import dev.mcsre.payments.obs.JsonLog;
import dev.mcsre.payments.obs.RequestScope;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;
import java.util.function.Supplier;
import javax.sql.DataSource;

/**
 * Payments in PostgreSQL. The unique idempotency key is the arbiter: the insert uses ON CONFLICT DO
 * NOTHING, so of any number of concurrent requests with one key exactly one row is written and the
 * others read it back. A key that exists with a different request hash is a mismatch.
 */
public final class PostgresPaymentRepository implements PaymentRepository {

    private static final String COLUMNS =
            "id, order_id, amount_minor, currency, status, decline_reason, created_at, request_hash";
    private static final long SLOW_QUERY_NANOS = 250_000_000L;

    private record Row(Payment payment, String fingerprint) {}

    private final DataSource dataSource;
    private final DbMetrics metrics;
    private final JsonLog log;

    public PostgresPaymentRepository(DataSource dataSource, DbMetrics metrics, JsonLog log) {
        this.dataSource = dataSource;
        this.metrics = metrics;
        this.log = log;
    }

    @Override
    public Stored saveIfAbsent(String key, String fingerprint, Supplier<Payment> create) {
        return timed("save_payment", () -> {
            try (Connection connection = dataSource.getConnection()) {
                Optional<Row> existing = findByKey(connection, key);
                if (existing.isPresent()) {
                    return replay(existing.get(), key, fingerprint);
                }
                Payment payment = create.get();
                if (insert(connection, key, fingerprint, payment)) {
                    return new Stored(payment, true);
                }
                // Another request with this key won the race between our read and our insert.
                Row winner = findByKey(connection, key).orElseThrow(
                        () -> new SQLException("payment vanished after a unique conflict"));
                return replay(winner, key, fingerprint);
            }
        });
    }

    private static Stored replay(Row row, String key, String fingerprint) {
        if (!row.fingerprint().equals(fingerprint)) {
            throw new KeyMismatchException(key);
        }
        return new Stored(row.payment(), false);
    }

    @Override
    public Optional<Payment> findById(String id) {
        UUID uuid;
        try {
            uuid = UUID.fromString(id);
        } catch (IllegalArgumentException e) {
            return Optional.empty();
        }
        return timed("get_payment", () -> {
            try (Connection connection = dataSource.getConnection();
                    PreparedStatement statement = connection.prepareStatement(
                            "SELECT " + COLUMNS + " FROM payments WHERE id = ?")) {
                statement.setObject(1, uuid);
                try (ResultSet rows = statement.executeQuery()) {
                    return rows.next() ? Optional.of(read(rows).payment()) : Optional.<Payment>empty();
                }
            }
        });
    }

    @Override
    public void ready() throws SQLException {
        // Selecting from the table also proves the migrations have run.
        try (Connection connection = dataSource.getConnection();
                PreparedStatement statement = connection.prepareStatement("SELECT 1 FROM payments LIMIT 1")) {
            statement.setQueryTimeout(2);
            statement.execute();
        }
    }

    private static Optional<Row> findByKey(Connection connection, String key) throws SQLException {
        try (PreparedStatement statement = connection.prepareStatement(
                "SELECT " + COLUMNS + " FROM payments WHERE idempotency_key = ?")) {
            statement.setString(1, key);
            try (ResultSet rows = statement.executeQuery()) {
                return rows.next() ? Optional.of(read(rows)) : Optional.empty();
            }
        }
    }

    private static boolean insert(Connection connection, String key, String fingerprint, Payment payment)
            throws SQLException {
        try (PreparedStatement statement = connection.prepareStatement(
                "INSERT INTO payments (id, idempotency_key, request_hash, order_id, amount_minor, currency, status,"
                        + " decline_reason, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)"
                        + " ON CONFLICT (idempotency_key) DO NOTHING")) {
            statement.setObject(1, UUID.fromString(payment.id()));
            statement.setString(2, key);
            statement.setString(3, fingerprint);
            statement.setString(4, payment.orderId());
            statement.setLong(5, payment.amountMinor());
            statement.setString(6, payment.currency());
            statement.setString(7, payment.status().wire());
            statement.setString(8, payment.declineReason());
            statement.setObject(9, OffsetDateTime.ofInstant(payment.createdAt(), ZoneOffset.UTC));
            return statement.executeUpdate() == 1;
        }
    }

    private static Row read(ResultSet rows) throws SQLException {
        Payment.Status status = "approved".equals(rows.getString("status"))
                ? Payment.Status.APPROVED
                : Payment.Status.DECLINED;
        Payment payment = new Payment(
                rows.getObject("id", UUID.class).toString(),
                rows.getString("order_id"),
                rows.getLong("amount_minor"),
                rows.getString("currency").trim(),
                status,
                rows.getString("decline_reason"),
                rows.getObject("created_at", OffsetDateTime.class).toInstant());
        return new Row(payment, rows.getString("request_hash"));
    }

    /** Runs a database call, records its latency and turns a database failure into a retryable error. */
    private <T> T timed(String operation, SqlCall<T> call) {
        long start = System.nanoTime();
        try {
            return call.run();
        } catch (SQLException e) {
            Map<String, Object> fields = fields(operation);
            fields.put("error", e.getClass().getSimpleName());
            fields.put("sqlstate", String.valueOf(e.getSQLState()));
            log.warn("database call failed", fields);
            throw new StorageUnavailableException("database unavailable", e);
        } finally {
            long elapsed = System.nanoTime() - start;
            metrics.observe(operation, elapsed);
            if (elapsed > SLOW_QUERY_NANOS) {
                Map<String, Object> fields = fields(operation);
                fields.put("duration_ms", elapsed / 1_000_000);
                log.warn("slow database call", fields);
            }
        }
    }

    private static Map<String, Object> fields(String operation) {
        Map<String, Object> fields = new LinkedHashMap<>();
        fields.put("operation", operation);
        fields.put("request_id", RequestScope.requestId());
        fields.put("trace_id", RequestScope.traceId());
        return fields;
    }

    @FunctionalInterface
    private interface SqlCall<T> {
        T run() throws SQLException;
    }
}
