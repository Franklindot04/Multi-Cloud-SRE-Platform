package dev.mcsre.payments.data;

import dev.mcsre.payments.config.AppConfig;
import dev.mcsre.payments.obs.JsonLog;
import java.io.PrintStream;
import java.util.Map;
import java.util.function.Function;
import org.flywaydb.core.api.output.MigrateResult;

/**
 * {@code java -jar payments.jar migrate}: applies the pending migrations and exits. It is a separate
 * step on purpose, so it can run as a one-shot container, an init container or a Kubernetes Job
 * before the service starts, and the service itself never changes the schema.
 */
public final class MigrateCommand {

    private MigrateCommand() {}

    /** Returns the process exit code: 0 on success, 2 for a configuration problem, 1 for a failed migration. */
    public static int run(Function<String, String> env, PrintStream out) {
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
        JsonLog log = new JsonLog("payments-migrate", config.logLevel(), out);
        try {
            MigrateResult result = Database.migrate(config.db());
            log.info("migrations applied", Map.of(
                    "applied", result.migrationsExecuted,
                    "schema_version", result.targetSchemaVersion == null ? "unchanged" : result.targetSchemaVersion));
            return 0;
        } catch (RuntimeException e) {
            log.error("migration failed", Map.of("error", e.getClass().getSimpleName(), "detail", String.valueOf(e.getMessage())));
            return 1;
        }
    }
}
