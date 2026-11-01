package dev.mcsre.payments.web;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import dev.mcsre.payments.obs.ObservabilityFilter;
import dev.mcsre.payments.obs.Tracing;
import io.opentelemetry.api.trace.SpanKind;
import io.opentelemetry.api.trace.StatusCode;
import io.opentelemetry.sdk.testing.exporter.InMemorySpanExporter;
import io.opentelemetry.sdk.trace.SdkTracerProvider;
import io.opentelemetry.sdk.trace.data.SpanData;
import io.opentelemetry.sdk.trace.export.SimpleSpanProcessor;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.boot.web.servlet.FilterRegistrationBean;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Import;
import org.springframework.context.annotation.Primary;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.web.context.WebApplicationContext;

/** A 5xx answer sets the status of the server span to error. */
@SpringBootTest(properties = {"FAULT_INJECTION_ENABLED=true", "FAULT_ERROR_RATE=1", "SHUTDOWN_DRAIN_SECONDS=0"})
@Import(TracingFailureTest.TestTracing.class)
class TracingFailureTest {

    static final InMemorySpanExporter EXPORTER = InMemorySpanExporter.create();

    @TestConfiguration
    static class TestTracing {
        @Bean
        @Primary
        Tracing memoryTracing() {
            return Tracing.of(SdkTracerProvider.builder().addSpanProcessor(SimpleSpanProcessor.create(EXPORTER)).build());
        }
    }

    @Autowired WebApplicationContext context;
    @Autowired FilterRegistrationBean<ObservabilityFilter> filter;

    MockMvc mvc;

    @BeforeEach
    void setUp() {
        EXPORTER.reset();
        mvc = ApiTestSupport.mockMvc(context, filter);
    }

    @Test
    void aServerErrorMarksTheSpanWithAFixedDescription() throws Exception {
        mvc.perform(get("/payments/abc")).andExpect(status().isServiceUnavailable());

        SpanData server = EXPORTER.getFinishedSpanItems().stream().filter(s -> s.getKind() == SpanKind.SERVER).findFirst().orElseThrow();
        assertThat(server.getStatus().getStatusCode()).isEqualTo(StatusCode.ERROR);
        assertThat(server.getStatus().getDescription()).isEqualTo("server error");
    }
}
