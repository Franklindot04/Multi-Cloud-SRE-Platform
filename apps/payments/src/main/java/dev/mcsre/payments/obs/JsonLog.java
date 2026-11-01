package dev.mcsre.payments.obs;

import io.opentelemetry.api.trace.Span;
import io.opentelemetry.api.trace.SpanContext;
import java.io.PrintStream;
import java.time.Instant;
import java.time.temporal.ChronoUnit;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** One JSON object per line on stdout, with a fixed set of leading fields. */
public final class JsonLog {

    private static final List<String> LEVELS = List.of("debug", "info", "warn", "error");

    private final String service;
    private final int threshold;
    private final PrintStream out;

    public JsonLog(String service, String level, PrintStream out) {
        this.service = service;
        this.threshold = Math.max(0, LEVELS.indexOf(level));
        this.out = out;
    }

    public void log(String level, String message, Map<String, Object> fields) {
        if (LEVELS.indexOf(level) < threshold) {
            return;
        }
        Map<String, Object> record = new LinkedHashMap<>();
        record.put("timestamp", Instant.now().truncatedTo(ChronoUnit.MILLIS).toString());
        record.put("level", level);
        record.put("message", message);
        record.put("service", service);
        // A line written inside a span carries its trace ID, in the same form as the request line.
        SpanContext span = Span.current().getSpanContext();
        if (span.isValid()) {
            record.put("trace_id", span.getTraceId());
        }
        record.putAll(fields);
        out.println(toJson(record));
        out.flush();
    }

    public void info(String message, Map<String, Object> fields) {
        log("info", message, fields);
    }

    public void warn(String message, Map<String, Object> fields) {
        log("warn", message, fields);
    }

    public void error(String message, Map<String, Object> fields) {
        log("error", message, fields);
    }

    static String toJson(Map<String, Object> map) {
        StringBuilder sb = new StringBuilder("{");
        boolean first = true;
        for (Map.Entry<String, Object> e : map.entrySet()) {
            if (!first) {
                sb.append(',');
            }
            first = false;
            sb.append('"').append(escape(e.getKey())).append("\":");
            Object v = e.getValue();
            if (v instanceof Number || v instanceof Boolean) {
                sb.append(v);
            } else {
                sb.append('"').append(escape(String.valueOf(v))).append('"');
            }
        }
        return sb.append('}').toString();
    }

    private static String escape(String s) {
        StringBuilder sb = new StringBuilder(s.length() + 8);
        for (char c : s.toCharArray()) {
            switch (c) {
                case '"' -> sb.append("\\\"");
                case '\\' -> sb.append("\\\\");
                case '\n' -> sb.append("\\n");
                case '\r' -> sb.append("\\r");
                case '\t' -> sb.append("\\t");
                default -> {
                    if (c < 0x20) {
                        sb.append(String.format("\\u%04x", (int) c));
                    } else {
                        sb.append(c);
                    }
                }
            }
        }
        return sb.toString();
    }
}
