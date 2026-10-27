package dev.mcsre.payments.obs;

import java.security.SecureRandom;
import java.util.HexFormat;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** W3C traceparent handling: keep the trace, never reuse a span. */
public final class TraceContext {

    private static final Pattern PATTERN = Pattern.compile("^00-([0-9a-f]{32})-([0-9a-f]{16})-([0-9a-f]{2})$");
    private static final SecureRandom RANDOM = new SecureRandom();

    private final String traceId;
    private final String flags;

    private TraceContext(String traceId, String flags) {
        this.traceId = traceId;
        this.flags = flags;
    }

    /** Parses an inbound header; starts a new trace when it is missing or invalid. */
    public static TraceContext fromHeader(String header) {
        if (header != null) {
            Matcher m = PATTERN.matcher(header);
            if (m.matches() && !m.group(1).matches("0+") && !m.group(2).matches("0+")) {
                return new TraceContext(m.group(1), m.group(3));
            }
        }
        return new TraceContext(randomHex(16), "01");
    }

    public String traceId() {
        return traceId;
    }

    /** The traceparent to send on a call to another service: same trace, new span. */
    public String outbound() {
        return "00-" + traceId + "-" + randomHex(8) + "-" + flags;
    }

    private static String randomHex(int bytes) {
        byte[] b = new byte[bytes];
        RANDOM.nextBytes(b);
        return HexFormat.of().formatHex(b);
    }
}
