package dev.mcsre.payments.data;

import dev.mcsre.payments.config.AppConfig;
import dev.mcsre.payments.obs.JsonLog;
import java.io.PrintStream;
import java.net.ConnectException;
import java.net.SocketTimeoutException;
import java.net.UnknownHostException;
import java.sql.SQLException;
import java.util.Map;
import java.util.Set;
import java.util.function.Function;
import java.util.function.LongSupplier;
import org.flywaydb.core.api.output.MigrateResult;

/**
 * {@code java -jar payments.jar migrate}: applies the pending migrations and exits. It is a separate
 * step on purpose, so it can run as a one-shot container, an init container or a Kubernetes Job
 * before the service starts, and the service itself never changes the schema.
 *
 * <p>With {@code MIGRATE_WAIT_SECONDS} above zero it waits for a database that is not ready yet (unreachable,
 * starting, the role or its password not set up yet, the database not created) and retries every
 * {@code MIGRATE_RETRY_INTERVAL_SECONDS} (default 5), logging each attempt. Waiting happens inside the
 * process, so a Kubernetes Job's retry budget is not used up while the database comes up. Other failures,
 * such as a bad migration or a changed checksum, fail at once.
 */
public final class MigrateCommand {

    /** Runs the migrations against the configured database. */
    @FunctionalInterface
    interface Migrator {
        MigrateResult migrate(AppConfig.Db db, int connectRetries);
    }

    /** SQLSTATEs that mean "not ready yet": bad or missing role or password, missing database, starting up. */
    private static final Set<String> NOT_READY_STATES = Set.of("28000", "28P01", "3D000", "57P03", "53300");

    private MigrateCommand() {}

    /** Returns the process exit code: 0 on success, 2 for a configuration problem, 1 for a failed migration. */
    public static int run(Function<String, String> env, PrintStream out) {
        return run(env, out, Database::migrate, System::currentTimeMillis, Thread::sleep);
    }

    /** Sleeps for the given number of milliseconds. */
    @FunctionalInterface
    interface Sleeper {
        void sleep(long millis) throws InterruptedException;
    }

    static int run(Function<String, String> env, PrintStream out, Migrator migrator, LongSupplier clock, Sleeper sleeper) {
        AppConfig config;
        try {
            config = AppConfig.load(env);
        } catch (AppConfig.ConfigException e) {
            System.err.println("invalid configuration:\n" + e.getMessage());
            return 2;
        }
        if (config.db() == null) {
            System.err.println("invalid configuration:\nSTORAGE must be postgres to run migrations");
            return 2;
        }
        long waitSeconds;
        long intervalSeconds;
        try {
            waitSeconds = number(env.apply("MIGRATE_WAIT_SECONDS"), 0, 0, 3600, "MIGRATE_WAIT_SECONDS");
            intervalSeconds = number(env.apply("MIGRATE_RETRY_INTERVAL_SECONDS"), 5, 1, 60, "MIGRATE_RETRY_INTERVAL_SECONDS");
        } catch (IllegalArgumentException e) {
            System.err.println("invalid configuration:\n" + e.getMessage());
            return 2;
        }
        JsonLog log = new JsonLog("payments-migrate", config.logLevel(), out);
        long start = clock.getAsLong();
        int attempt = 0;
        while (true) {
            attempt++;
            try {
                // While waiting, the loop below is the retry; Flyway's own connection retries would only delay it.
                MigrateResult result = migrator.migrate(config.db(), waitSeconds > 0 ? 0 : 5);
                log.info("migrations applied", Map.of(
                        "applied", result.migrationsExecuted,
                        "schema_version", result.targetSchemaVersion == null ? "unchanged" : result.targetSchemaVersion));
                return 0;
            } catch (RuntimeException e) {
                long waited = (clock.getAsLong() - start) / 1000;
                if (!isNotReady(e) || waited + intervalSeconds > waitSeconds) {
                    log.error("migration failed", Map.of("error", e.getClass().getSimpleName(), "detail", String.valueOf(e.getMessage())));
                    return 1;
                }
                log.warn("database not ready, retrying", Map.of(
                        "attempt", attempt,
                        "retry_in_s", intervalSeconds,
                        "waited_s", waited,
                        "wait_s", waitSeconds,
                        "detail", rootMessage(e)));
                try {
                    sleeper.sleep(intervalSeconds * 1000);
                } catch (InterruptedException interrupted) {
                    Thread.currentThread().interrupt();
                    return 1;
                }
            }
        }
    }

    private static long number(String raw, long def, long low, long high, String name) {
        if (raw == null || raw.isBlank()) {
            return def;
        }
        try {
            long value = Long.parseLong(raw.trim());
            if (value >= low && value <= high) {
                return value;
            }
        } catch (NumberFormatException ignored) {
            // reported below
        }
        throw new IllegalArgumentException(name + " must be an integer between " + low + " and " + high + ", got '" + raw + "'");
    }

    /** True when the failure is about the database or its role not being ready, anywhere in the cause chain. */
    static boolean isNotReady(Throwable error) {
        for (Throwable t = error; t != null; t = t.getCause()) {
            if (t instanceof ConnectException || t instanceof SocketTimeoutException || t instanceof UnknownHostException) {
                return true;
            }
            if (t instanceof SQLException sql) {
                String state = sql.getSQLState();
                if (state != null && (state.startsWith("08") || NOT_READY_STATES.contains(state))) {
                    return true;
                }
            }
            if (t.getCause() == t) {
                break;
            }
        }
        return false;
    }

    private static String rootMessage(Throwable error) {
        Throwable t = error;
        while (t.getCause() != null && t.getCause() != t) {
            t = t.getCause();
        }
        return t.getClass().getSimpleName() + ": " + t.getMessage();
    }
}
