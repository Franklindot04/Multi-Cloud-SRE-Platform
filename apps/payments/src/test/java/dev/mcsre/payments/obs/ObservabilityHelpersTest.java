package dev.mcsre.payments.obs;

import static org.assertj.core.api.Assertions.assertThat;

import java.io.ByteArrayOutputStream;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.util.Map;
import org.junit.jupiter.api.Test;

class ObservabilityHelpersTest {

    @Test
    void validTraceparentKeepsTheTraceAndGetsANewSpan() {
        String in = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01";
        TraceContext trace = TraceContext.fromHeader(in);
        assertThat(trace.traceId()).isEqualTo("4bf92f3577b34da6a3ce929d0e0e4736");
        String out = trace.outbound();
        assertThat(out).startsWith("00-4bf92f3577b34da6a3ce929d0e0e4736-").endsWith("-01").isNotEqualTo(in);
        assertThat(out).doesNotContain("00f067aa0ba902b7");
    }

    @Test
    void invalidOrMissingTraceparentStartsANewTrace() {
        String[] bad = {
            null,
            "",
            "garbage",
            "00-00000000000000000000000000000000-00f067aa0ba902b7-01",
            "00-4bf92f3577b34da6a3ce929d0e0e4736-0000000000000000-01",
            "01-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
        };
        for (String header : bad) {
            assertThat(TraceContext.fromHeader(header).traceId()).matches("[0-9a-f]{32}").isNotEqualTo("4bf92f3577b34da6a3ce929d0e0e4736");
        }
    }

    @Test
    void logLinesAreJsonWithTheLeadingFields() {
        ByteArrayOutputStream buffer = new ByteArrayOutputStream();
        JsonLog log = new JsonLog("payments", "info", new PrintStream(buffer, true, StandardCharsets.UTF_8));
        log.info("request", Map.of("status", 200, "route", "/payments/{id}", "note", "say \"hi\"\n"));
        log.log("debug", "hidden", Map.of());
        String line = buffer.toString(StandardCharsets.UTF_8).trim();
        assertThat(line.split("\n")).hasSize(1);
        assertThat(line).startsWith("{\"timestamp\":\"").contains("\"level\":\"info\"", "\"message\":\"request\"", "\"service\":\"payments\"");
        assertThat(line).contains("\"status\":200", "\"route\":\"/payments/{id}\"", "say \\\"hi\\\"\\n");
    }

    @Test
    void errorEnvelopeHasCodeMessageAndRequestId() {
        assertThat(ErrorJson.of("not_found", "nope", "rid-1"))
                .isEqualTo("{\"error\":{\"code\":\"not_found\",\"message\":\"nope\",\"request_id\":\"rid-1\"}}");
    }

    @Test
    void drainFlipsOnce() {
        Drain drain = new Drain();
        assertThat(drain.isDraining()).isFalse();
        drain.start();
        assertThat(drain.isDraining()).isTrue();
    }
}
