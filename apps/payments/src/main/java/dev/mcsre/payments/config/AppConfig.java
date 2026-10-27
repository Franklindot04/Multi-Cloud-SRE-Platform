package dev.mcsre.payments.config;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import java.util.function.Function;

/**
 * Validated configuration, read only from environment variables (or Spring properties of the same
 * name in tests). Every problem is reported together.
 */
public record AppConfig(
        int port,
        String logLevel,
        long maxBodyBytes,
        int maxPayments,
        long declineAboveMinor,
        double approvalRatio,
        Set<String> allowedCurrencies,
        int drainSeconds,
        int shutdownTimeoutSeconds,
        boolean faultEnabled,
        int faultLatencyMs,
        double faultErrorRate,
        String storage,
        Db db) {

    /** PostgreSQL settings; present only when STORAGE=postgres. The password never appears in toString. */
    public record Db(
            String host,
            int port,
            String name,
            String user,
            String password,
            int poolMax,
            int connectTimeoutMs,
            int statementTimeoutMs) {

        @Override
        public String toString() {
            return "Db[host=" + host + ", port=" + port + ", name=" + name + ", user=" + user + "]";
        }
    }

    /** Thrown with all configuration problems at once. */
    public static class ConfigException extends RuntimeException {
        public ConfigException(String message) {
            super(message);
        }
    }

    public static AppConfig load(Function<String, String> env) {
        Reader r = new Reader(env);
        String storage = r.oneOf("STORAGE", "memory", "memory", "postgres");
        AppConfig config = new AppConfig(
                r.integer("PORT", 8082, 1, 65535),
                r.oneOf("LOG_LEVEL", "info", "debug", "info", "warn", "error"),
                r.integer("MAX_BODY_BYTES", 1 << 20, 1, 64 << 20),
                r.integer("MAX_PAYMENTS", 100_000, 1, 10_000_000),
                r.integer("PAYMENT_DECLINE_ABOVE_MINOR", 100_000, 1, Integer.MAX_VALUE),
                r.number("PAYMENT_APPROVAL_RATIO", 1.0, 0.0, 1.0),
                r.currencies("PAYMENT_ALLOWED_CURRENCIES", "USD,EUR,GBP,SEK"),
                r.integer("SHUTDOWN_DRAIN_SECONDS", 5, 0, 300),
                r.integer("SHUTDOWN_TIMEOUT_SECONDS", 20, 1, 600),
                r.bool("FAULT_INJECTION_ENABLED", false),
                r.integer("FAULT_LATENCY_MS", 0, 0, 60000),
                r.number("FAULT_ERROR_RATE", 0.0, 0.0, 1.0),
                storage,
                storage.equals("postgres") ? r.db() : null);
        if (!r.errors.isEmpty()) {
            throw new ConfigException(String.join("\n", r.errors));
        }
        return config;
    }

    private static final class Reader {
        private final Function<String, String> env;
        private final List<String> errors = new ArrayList<>();

        Reader(Function<String, String> env) {
            this.env = env;
        }

        private String raw(String key) {
            String value = env.apply(key);
            return value == null || value.isBlank() ? null : value.trim();
        }

        String text(String key, String def) {
            String raw = raw(key);
            return raw == null ? def : raw;
        }

        /** A secret from KEY or, for a mounted secret file, KEY_FILE. Required; never both. */
        String secret(String key) {
            String value = raw(key);
            String file = raw(key + "_FILE");
            if (value != null && file != null) {
                errors.add(key + " and " + key + "_FILE are both set; use one");
                return "";
            }
            if (file != null) {
                try {
                    String content = Files.readString(Path.of(file)).strip();
                    if (!content.isEmpty()) {
                        return content;
                    }
                    errors.add(key + "_FILE points to an empty file");
                } catch (IOException | RuntimeException e) {
                    errors.add(key + "_FILE cannot be read: " + file);
                }
                return "";
            }
            if (value == null) {
                errors.add(key + " or " + key + "_FILE is required when STORAGE=postgres");
                return "";
            }
            return value;
        }

        Db db() {
            return new Db(
                    text("DB_HOST", "postgres"),
                    integer("DB_PORT", 5432, 1, 65535),
                    text("DB_NAME", "payments"),
                    text("DB_USER", "payments"),
                    secret("DB_PASSWORD"),
                    integer("DB_POOL_MAX", 5, 1, 100),
                    integer("DB_CONNECT_TIMEOUT_MS", 3000, 100, 60000),
                    integer("DB_STATEMENT_TIMEOUT_MS", 5000, 100, 600000));
        }

        int integer(String key, int def, int low, int high) {
            String raw = raw(key);
            if (raw == null) {
                return def;
            }
            try {
                long value = Long.parseLong(raw);
                if (value >= low && value <= high) {
                    return (int) value;
                }
            } catch (NumberFormatException ignored) {
                // reported below
            }
            errors.add(key + " must be an integer between " + low + " and " + high + ", got '" + raw + "'");
            return def;
        }

        double number(String key, double def, double low, double high) {
            String raw = raw(key);
            if (raw == null) {
                return def;
            }
            try {
                double value = Double.parseDouble(raw);
                if (value >= low && value <= high) {
                    return value;
                }
            } catch (NumberFormatException ignored) {
                // reported below
            }
            errors.add(key + " must be a number between " + low + " and " + high + ", got '" + raw + "'");
            return def;
        }

        boolean bool(String key, boolean def) {
            String raw = raw(key);
            if (raw == null) {
                return def;
            }
            if (raw.equalsIgnoreCase("true") || raw.equalsIgnoreCase("false")) {
                return Boolean.parseBoolean(raw);
            }
            errors.add(key + " must be true or false, got '" + raw + "'");
            return def;
        }

        String oneOf(String key, String def, String... allowed) {
            String raw = raw(key);
            String value = raw == null ? def : raw;
            if (!Arrays.asList(allowed).contains(value)) {
                errors.add(key + " must be one of " + String.join(", ", allowed) + ", got '" + value + "'");
                return def;
            }
            return value;
        }

        Set<String> currencies(String key, String def) {
            String raw = raw(key);
            Set<String> out = new LinkedHashSet<>();
            for (String part : (raw == null ? def : raw).split(",")) {
                String code = part.trim();
                if (!code.matches("[A-Z]{3}")) {
                    errors.add(key + " must be a comma-separated list of 3-letter upper-case currency codes, got '" + code + "'");
                    return Set.copyOf(Arrays.asList(def.split(",")));
                }
                out.add(code);
            }
            return Set.copyOf(out);
        }
    }
}
