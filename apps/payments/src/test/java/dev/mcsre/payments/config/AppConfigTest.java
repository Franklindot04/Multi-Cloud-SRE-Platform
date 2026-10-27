package dev.mcsre.payments.config;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.util.Map;
import org.junit.jupiter.api.Test;

class AppConfigTest {

    private static AppConfig load(Map<String, String> env) {
        return AppConfig.load(env::get);
    }

    @Test
    void defaultsAreSensible() {
        AppConfig c = load(Map.of());
        assertThat(c.port()).isEqualTo(8082);
        assertThat(c.declineAboveMinor()).isEqualTo(100_000);
        assertThat(c.approvalRatio()).isEqualTo(1.0);
        assertThat(c.allowedCurrencies()).containsExactlyInAnyOrder("USD", "EUR", "GBP", "SEK");
        assertThat(c.faultEnabled()).isFalse();
        assertThat(c.maxBodyBytes()).isEqualTo(1 << 20);
    }

    @Test
    void everyProblemIsReportedTogether() {
        assertThatThrownBy(() -> load(Map.of(
                        "PORT", "99999",
                        "PAYMENT_APPROVAL_RATIO", "1.5",
                        "PAYMENT_ALLOWED_CURRENCIES", "usd",
                        "FAULT_INJECTION_ENABLED", "yes",
                        "LOG_LEVEL", "loud")))
                .isInstanceOf(AppConfig.ConfigException.class)
                .hasMessageContaining("PORT")
                .hasMessageContaining("PAYMENT_APPROVAL_RATIO")
                .hasMessageContaining("PAYMENT_ALLOWED_CURRENCIES")
                .hasMessageContaining("FAULT_INJECTION_ENABLED")
                .hasMessageContaining("LOG_LEVEL");
    }

    @Test
    void faultAndSimulationSettingsAreRead() {
        AppConfig c = load(Map.of(
                "FAULT_INJECTION_ENABLED", "true",
                "FAULT_LATENCY_MS", "250",
                "FAULT_ERROR_RATE", "0.25",
                "PAYMENT_DECLINE_ABOVE_MINOR", "5000",
                "PAYMENT_APPROVAL_RATIO", "0.5",
                "PAYMENT_ALLOWED_CURRENCIES", "USD, NOK"));
        assertThat(c.faultEnabled()).isTrue();
        assertThat(c.faultLatencyMs()).isEqualTo(250);
        assertThat(c.faultErrorRate()).isEqualTo(0.25);
        assertThat(c.declineAboveMinor()).isEqualTo(5000);
        assertThat(c.approvalRatio()).isEqualTo(0.5);
        assertThat(c.allowedCurrencies()).containsExactlyInAnyOrder("USD", "NOK");
    }

    @Test
    void blankValuesFallBackToDefaults() {
        assertThat(load(Map.of("PORT", "  ")).port()).isEqualTo(8082);
    }

    @Test
    void storageDefaultsToMemoryWithoutDatabaseSettings() {
        AppConfig c = load(Map.of());
        assertThat(c.storage()).isEqualTo("memory");
        assertThat(c.db()).isNull();
    }

    @Test
    void postgresNeedsAPasswordAndReportsItClearly() {
        assertThatThrownBy(() -> load(Map.of("STORAGE", "postgres")))
                .isInstanceOf(AppConfig.ConfigException.class)
                .hasMessageContaining("DB_PASSWORD");
        assertThatThrownBy(() -> load(Map.of("STORAGE", "mysql")))
                .isInstanceOf(AppConfig.ConfigException.class)
                .hasMessageContaining("STORAGE");
    }

    @Test
    void postgresSettingsAreReadAndThePasswordIsNotPrinted() {
        AppConfig c = load(Map.of("STORAGE", "postgres", "DB_PASSWORD", "s3cret-value", "DB_HOST", "db.internal", "DB_POOL_MAX", "8"));
        assertThat(c.db().host()).isEqualTo("db.internal");
        assertThat(c.db().poolMax()).isEqualTo(8);
        assertThat(c.db().user()).isEqualTo("payments");
        assertThat(c.db().toString()).doesNotContain("s3cret-value");
        assertThat(c.toString()).doesNotContain("s3cret-value");
    }

    @Test
    void thePasswordCanComeFromAMountedFile(@org.junit.jupiter.api.io.TempDir java.nio.file.Path dir) throws Exception {
        java.nio.file.Path file = dir.resolve("password");
        java.nio.file.Files.writeString(file, "from-file\n");
        AppConfig c = load(Map.of("STORAGE", "postgres", "DB_PASSWORD_FILE", file.toString()));
        assertThat(c.db().password()).isEqualTo("from-file");
        assertThatThrownBy(() -> load(Map.of("STORAGE", "postgres", "DB_PASSWORD", "x", "DB_PASSWORD_FILE", file.toString())))
                .hasMessageContaining("both set");
        assertThatThrownBy(() -> load(Map.of("STORAGE", "postgres", "DB_PASSWORD_FILE", dir.resolve("missing").toString())))
                .hasMessageContaining("cannot be read");
    }
}
