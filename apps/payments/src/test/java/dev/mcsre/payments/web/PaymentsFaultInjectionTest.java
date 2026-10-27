package dev.mcsre.payments.web;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import dev.mcsre.payments.obs.ObservabilityFilter;
import org.junit.jupiter.api.Nested;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.web.servlet.FilterRegistrationBean;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.web.context.WebApplicationContext;

class PaymentsFaultInjectionTest {

    @Nested
    @SpringBootTest(properties = {"FAULT_INJECTION_ENABLED=true", "FAULT_ERROR_RATE=1.0"})
    class ErrorsWhenEnabled {
        @Autowired WebApplicationContext context;
        @Autowired FilterRegistrationBean<ObservabilityFilter> filter;

        @Test
        void businessEndpointsFailAndOperationalOnesDoNot() throws Exception {
            MockMvc mvc = ApiTestSupport.mockMvc(context, filter);
            mvc.perform(get("/payments/anything")).andExpect(status().isServiceUnavailable()).andExpect(jsonPath("$.error.code").value("fault_injected"));
            for (String path : new String[] {"/healthz", "/readyz", "/metrics"}) {
                mvc.perform(get(path)).andExpect(status().isOk());
            }
            String metrics = mvc.perform(get("/metrics")).andReturn().getResponse().getContentAsString();
            assertThat(metrics).contains("route=\"/payments/{id}\"", "status=\"503\"");
        }
    }

    @Nested
    @SpringBootTest(properties = {"FAULT_INJECTION_ENABLED=true", "FAULT_LATENCY_MS=150"})
    class LatencyWhenEnabled {
        @Autowired WebApplicationContext context;
        @Autowired FilterRegistrationBean<ObservabilityFilter> filter;

        @Test
        void onlyBusinessEndpointsAreDelayed() throws Exception {
            MockMvc mvc = ApiTestSupport.mockMvc(context, filter);
            long start = System.nanoTime();
            mvc.perform(get("/payments/anything"));
            assertThat((System.nanoTime() - start) / 1_000_000).isGreaterThanOrEqualTo(150);
            start = System.nanoTime();
            mvc.perform(get("/healthz")).andExpect(status().isOk());
            assertThat((System.nanoTime() - start) / 1_000_000).isLessThan(100);
        }
    }

    @Nested
    @SpringBootTest(properties = {"FAULT_INJECTION_ENABLED=false", "FAULT_ERROR_RATE=1.0", "FAULT_LATENCY_MS=500"})
    class IgnoredWhenDisabled {
        @Autowired WebApplicationContext context;
        @Autowired FilterRegistrationBean<ObservabilityFilter> filter;

        @Test
        void otherFaultSettingsHaveNoEffect() throws Exception {
            MockMvc mvc = ApiTestSupport.mockMvc(context, filter);
            long start = System.nanoTime();
            mvc.perform(get("/payments/anything")).andExpect(status().isNotFound());
            assertThat((System.nanoTime() - start) / 1_000_000).isLessThan(300);
        }
    }
}
