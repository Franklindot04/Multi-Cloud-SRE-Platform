package dev.mcsre.payments.data;

import com.zaxxer.hikari.HikariConfig;
import com.zaxxer.hikari.HikariDataSource;
import dev.mcsre.payments.config.AppConfig;
import org.flywaydb.core.Flyway;
import org.flywaydb.core.api.output.MigrateResult;

/** Connection pool and schema migrations for the payments database. */
public final class Database {

    private Database() {}

    static String url(AppConfig.Db db) {
        return "jdbc:postgresql://" + db.host() + ":" + db.port() + "/" + db.name();
    }

    /**
     * A small pool with explicit timeouts. The pool does not fail the process when the database is
     * down at startup: /readyz reports it instead, so an orchestrator keeps the pod out of rotation.
     */
    public static HikariDataSource pool(AppConfig.Db db) {
        HikariConfig config = new HikariConfig();
        config.setPoolName("payments");
        config.setJdbcUrl(url(db));
        config.setUsername(db.user());
        config.setPassword(db.password());
        config.setMaximumPoolSize(db.poolMax());
        config.setMinimumIdle(Math.min(1, db.poolMax()));
        config.setConnectionTimeout(db.connectTimeoutMs());
        config.setValidationTimeout(Math.min(db.connectTimeoutMs(), 2000));
        config.setMaxLifetime(30 * 60_000L);
        config.setIdleTimeout(5 * 60_000L);
        config.setInitializationFailTimeout(-1);
        config.addDataSourceProperty("ApplicationName", "payments");
        config.addDataSourceProperty("connectTimeout", Integer.toString(Math.max(1, db.connectTimeoutMs() / 1000)));
        config.addDataSourceProperty("options", "-c statement_timeout=" + db.statementTimeoutMs() + " -c TimeZone=UTC");
        return new HikariDataSource(config);
    }

    /**
     * Applies the pending forward-only migrations in db/migration. Flyway serialises concurrent runs
     * with a PostgreSQL advisory lock, verifies the checksums of migrations that were applied
     * before, and the clean command is disabled.
     */
    public static MigrateResult migrate(AppConfig.Db db) {
        return migrate(db, 5);
    }

    /** Like {@link #migrate(AppConfig.Db)} with an explicit number of Flyway's own connection retries. */
    public static MigrateResult migrate(AppConfig.Db db, int connectRetries) {
        Flyway flyway = Flyway.configure()
                .dataSource(url(db), db.user(), db.password())
                .locations("classpath:db/migration")
                .cleanDisabled(true)
                .validateOnMigrate(true)
                .connectRetries(connectRetries)
                .load();
        return flyway.migrate();
    }
}
