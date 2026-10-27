package dev.mcsre.payments.web;

import dev.mcsre.payments.obs.Drain;
import io.prometheus.metrics.expositionformats.PrometheusTextFormatWriter;
import io.prometheus.metrics.model.registry.PrometheusRegistry;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.util.Map;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

/** Liveness, readiness and metrics. The payments service has no downstream dependencies. */
@RestController
public class OpsController {

    private final Drain drain;
    private final PrometheusRegistry registry;

    public OpsController(Drain drain, PrometheusRegistry registry) {
        this.drain = drain;
        this.registry = registry;
    }

    @GetMapping("/healthz")
    public Map<String, String> healthz() {
        return Map.of("status", "ok");
    }

    @GetMapping("/readyz")
    public ResponseEntity<Map<String, String>> readyz() {
        if (drain.isDraining()) {
            return ResponseEntity.status(HttpStatus.SERVICE_UNAVAILABLE).body(Map.of("status", "draining"));
        }
        return ResponseEntity.ok(Map.of("status", "ready"));
    }

    @GetMapping("/metrics")
    public ResponseEntity<byte[]> metrics() throws IOException {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        PrometheusTextFormatWriter.builder().build().write(out, registry.scrape());
        return ResponseEntity.ok().contentType(MediaType.parseMediaType("text/plain; version=0.0.4; charset=utf-8")).body(out.toByteArray());
    }
}
