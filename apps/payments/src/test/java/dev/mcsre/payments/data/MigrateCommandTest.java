package dev.mcsre.payments.data;

import static org.assertj.core.api.Assertions.assertThat;

import java.io.ByteArrayOutputStream;
import java.io.PrintStream;
import java.net.ConnectException;
import java.nio.charset.StandardCharsets;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import org.flywaydb.core.api.FlywayException;
import org.flywaydb.core.api.output.MigrateResult;
import org.junit.jupiter.api.Test;

class MigrateCommandTest {

    private static final Map<String, String> BASE = Map.of("STORAGE", "postgres", "DB_PASSWORD", "x");

    /** A clock the fake sleeper advances, so the tests take no real time. */
    private static final class Time {
        long now;
        final List<Long> slept = new ArrayList<>();
    }

    private static int run(Map<String, String> env, MigrateCommand.Migrator migrator, Time time, ByteArrayOutputStream out) {
        return MigrateCommand.run(env::get, new PrintStream(out, true, StandardCharsets.UTF_8), migrator, () -> time.now, millis -> {
            time.slept.add(millis);
            time.now += millis;
        });
    }

    private static MigrateResult applied() {
        return new MigrateResult("1", "payments", "PostgreSQL", "13");
    }

    private static FlywayException notReady(String sqlState) {
        return new FlywayException("Unable to obtain connection from database", new SQLException("not ready", sqlState));
    }

    @Test
    void waitsWhileTheRoleOrDatabaseIsNotReadyThenSucceeds() {
        Time time = new Time();
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        int[] calls = {0};
        int code = run(Map.of("STORAGE", "postgres", "DB_PASSWORD", "x", "MIGRATE_WAIT_SECONDS", "60"), (db, retries) -> {
            calls[0]++;
            assertThat(retries).isZero();
            if (calls[0] == 1) {
                throw notReady("28P01"); // password authentication failed: the role is not set up yet
            }
            if (calls[0] == 2) {
                throw new FlywayException("refused", new ConnectException("Connection refused"));
            }
            return applied();
        }, time, out);
        assertThat(code).isZero();
        assertThat(time.slept).containsExactly(5000L, 5000L);
        String log = out.toString(StandardCharsets.UTF_8);
        assertThat(log).contains("database not ready, retrying").contains("migrations applied");
        assertThat(log).doesNotContain("x\"");
    }

    @Test
    void givesUpAtTheDeadline() {
        Time time = new Time();
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        int code = run(Map.of("STORAGE", "postgres", "DB_PASSWORD", "x", "MIGRATE_WAIT_SECONDS", "12"), (db, retries) -> {
            throw notReady("3D000");
        }, time, out);
        assertThat(code).isEqualTo(1);
        assertThat(time.slept).hasSize(2);
        assertThat(out.toString(StandardCharsets.UTF_8)).contains("migration failed");
    }

    @Test
    void failsAtOnceByDefaultAndKeepsFlywaysOwnRetries() {
        Time time = new Time();
        int[] retriesSeen = {-1};
        int code = run(BASE, (db, retries) -> {
            retriesSeen[0] = retries;
            throw notReady("28P01");
        }, time, new ByteArrayOutputStream());
        assertThat(code).isEqualTo(1);
        assertThat(time.slept).isEmpty();
        assertThat(retriesSeen[0]).isEqualTo(5);
    }

    @Test
    void doesNotRetryErrorsThatAreNotAboutReadiness() {
        Time time = new Time();
        int[] calls = {0};
        int code = run(Map.of("STORAGE", "postgres", "DB_PASSWORD", "x", "MIGRATE_WAIT_SECONDS", "600"), (db, retries) -> {
            calls[0]++;
            throw new FlywayException("Validate failed: migration checksum mismatch", new SQLException("syntax", "42601"));
        }, time, new ByteArrayOutputStream());
        assertThat(code).isEqualTo(1);
        assertThat(calls[0]).isEqualTo(1);
    }

    @Test
    void rejectsBadWaitSettings() {
        assertThat(run(Map.of("STORAGE", "postgres", "DB_PASSWORD", "x", "MIGRATE_WAIT_SECONDS", "soon"),
                (db, retries) -> applied(), new Time(), new ByteArrayOutputStream())).isEqualTo(2);
        assertThat(run(Map.of("STORAGE", "postgres", "DB_PASSWORD", "x", "MIGRATE_RETRY_INTERVAL_SECONDS", "0"),
                (db, retries) -> applied(), new Time(), new ByteArrayOutputStream())).isEqualTo(2);
    }

    @Test
    void classifiesTheCauseChain() {
        assertThat(MigrateCommand.isNotReady(notReady("57P03"))).isTrue();
        assertThat(MigrateCommand.isNotReady(notReady("08006"))).isTrue();
        assertThat(MigrateCommand.isNotReady(notReady("42601"))).isFalse();
        assertThat(MigrateCommand.isNotReady(new IllegalStateException("x"))).isFalse();
    }
}
