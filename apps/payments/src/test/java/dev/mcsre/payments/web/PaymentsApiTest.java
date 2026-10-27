package dev.mcsre.payments.web;

import static dev.mcsre.payments.web.ApiTestSupport.BODY;
import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.delete;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.header;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import dev.mcsre.payments.obs.Drain;
import dev.mcsre.payments.obs.ObservabilityFilter;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.web.servlet.FilterRegistrationBean;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.web.context.WebApplicationContext;

@SpringBootTest(properties = {"PAYMENT_DECLINE_ABOVE_MINOR=5000", "SHUTDOWN_DRAIN_SECONDS=0"})
class PaymentsApiTest {

    @Autowired WebApplicationContext context;
    @Autowired FilterRegistrationBean<ObservabilityFilter> filter;
    @Autowired Drain drain;

    MockMvc mvc;

    @BeforeEach
    void setUp() {
        mvc = ApiTestSupport.mockMvc(context, filter);
    }

    private static org.springframework.test.web.servlet.request.MockHttpServletRequestBuilder authorize(String key, String body) {
        var request = post("/payments/authorize").contentType(MediaType.APPLICATION_JSON).content(body);
        return key == null ? request : request.header("Idempotency-Key", key);
    }

    @Test
    void approvesAPayment() throws Exception {
        mvc.perform(authorize("k-approve", BODY))
                .andExpect(status().isCreated())
                .andExpect(jsonPath("$.status").value("approved"))
                .andExpect(jsonPath("$.order_id").value("order-1"))
                .andExpect(jsonPath("$.amount_minor").value(2500))
                .andExpect(jsonPath("$.currency").value("USD"))
                .andExpect(jsonPath("$.decline_reason").doesNotExist())
                .andExpect(jsonPath("$.id").isNotEmpty())
                .andExpect(jsonPath("$.created_at").isNotEmpty());
    }

    @Test
    void declinesAmountsAboveTheConfiguredLimit() throws Exception {
        String body = "{\"order_id\":\"order-2\",\"amount_minor\":5001,\"currency\":\"USD\"}";
        mvc.perform(authorize("k-decline", body))
                .andExpect(status().isCreated())
                .andExpect(jsonPath("$.status").value("declined"))
                .andExpect(jsonPath("$.decline_reason").value("amount_exceeds_limit"));
    }

    @Test
    void sameKeyReturnsTheSameResultWith200() throws Exception {
        String first = mvc.perform(authorize("k-replay", BODY)).andExpect(status().isCreated()).andReturn().getResponse().getContentAsString();
        String second = mvc.perform(authorize("k-replay", BODY)).andExpect(status().isOk()).andReturn().getResponse().getContentAsString();
        assertThat(second).isEqualTo(first);
    }

    @Test
    void sameKeyWithADifferentBodyIs422() throws Exception {
        mvc.perform(authorize("k-mismatch", BODY)).andExpect(status().isCreated());
        mvc.perform(authorize("k-mismatch", BODY.replace("2500", "2600")))
                .andExpect(status().isUnprocessableEntity())
                .andExpect(jsonPath("$.error.code").value("idempotency_key_mismatch"));
    }

    @Test
    void missingOrInvalidKeyIs400() throws Exception {
        mvc.perform(authorize(null, BODY)).andExpect(status().isBadRequest()).andExpect(jsonPath("$.error.code").value("missing_idempotency_key"));
        mvc.perform(authorize("has space", BODY)).andExpect(status().isBadRequest());
        mvc.perform(authorize("x".repeat(129), BODY)).andExpect(status().isBadRequest());
    }

    @Test
    void invalidJsonIs400() throws Exception {
        mvc.perform(authorize("k-json", "{nope")).andExpect(status().isBadRequest()).andExpect(jsonPath("$.error.code").value("invalid_json"));
        mvc.perform(authorize("k-json", BODY.replace("}", ",\"extra\":1}"))).andExpect(status().isBadRequest());
    }

    @Test
    void validationErrorsAre422WithTheEnvelope() throws Exception {
        String[] bad = {
            "{\"amount_minor\":100,\"currency\":\"USD\"}",
            "{\"order_id\":\"o\",\"currency\":\"USD\"}",
            "{\"order_id\":\"o\",\"amount_minor\":0,\"currency\":\"USD\"}",
            "{\"order_id\":\"o\",\"amount_minor\":-5,\"currency\":\"USD\"}",
            "{\"order_id\":\"o\",\"amount_minor\":100,\"currency\":\"usd\"}",
            "{\"order_id\":\"\",\"amount_minor\":100,\"currency\":\"USD\"}"
        };
        for (String body : bad) {
            mvc.perform(authorize("k-bad", body))
                    .andExpect(status().isUnprocessableEntity())
                    .andExpect(jsonPath("$.error.code").value("validation_error"))
                    .andExpect(jsonPath("$.error.request_id").isNotEmpty());
        }
    }

    @Test
    void getReturnsTheStoredPaymentAnd404ForUnknownIds() throws Exception {
        String created = mvc.perform(authorize("k-get", BODY)).andReturn().getResponse().getContentAsString();
        String id = created.replaceAll(".*\"id\":\"([^\"]+)\".*", "$1");
        mvc.perform(get("/payments/" + id)).andExpect(status().isOk()).andExpect(jsonPath("$.id").value(id));
        mvc.perform(get("/payments/unknown")).andExpect(status().isNotFound()).andExpect(jsonPath("$.error.code").value("not_found"));
    }

    @Test
    void unknownRoutesAndWrongMethodsUseTheEnvelope() throws Exception {
        mvc.perform(get("/nope")).andExpect(status().isNotFound()).andExpect(jsonPath("$.error.code").value("not_found"));
        mvc.perform(delete("/payments/authorize")).andExpect(status().isMethodNotAllowed()).andExpect(jsonPath("$.error.code").value("method_not_allowed"));
        mvc.perform(post("/payments/authorize").contentType(MediaType.TEXT_PLAIN).content("x").header("Idempotency-Key", "k"))
                .andExpect(status().isUnsupportedMediaType());
    }

    @Test
    void requestIdIsGeneratedEchoedAndReplaced() throws Exception {
        String generated = mvc.perform(get("/healthz")).andReturn().getResponse().getHeader("X-Request-Id");
        assertThat(generated).hasSize(36);
        mvc.perform(get("/healthz").header("X-Request-Id", "abc-123")).andExpect(header().string("X-Request-Id", "abc-123"));
        String replaced = mvc.perform(get("/healthz").header("X-Request-Id", "bad id!")).andReturn().getResponse().getHeader("X-Request-Id");
        assertThat(replaced).isNotEqualTo("bad id!");
        mvc.perform(get("/payments/unknown").header("X-Request-Id", "trace-me")).andExpect(jsonPath("$.error.request_id").value("trace-me"));
    }

    @Test
    void healthzIsOkAndReadyzFollowsDrain() throws Exception {
        mvc.perform(get("/healthz")).andExpect(status().isOk()).andExpect(jsonPath("$.status").value("ok"));
        mvc.perform(get("/readyz")).andExpect(status().isOk()).andExpect(jsonPath("$.status").value("ready"));
        try {
            drain.start();
            mvc.perform(get("/readyz")).andExpect(status().isServiceUnavailable()).andExpect(jsonPath("$.status").value("draining"));
            mvc.perform(get("/healthz")).andExpect(status().isOk());
        } finally {
            // The drain flag is shared; a new context would be needed to reset it, so keep this test last in intent.
            resetDrain();
        }
    }

    private void resetDrain() {
        // Drain has no reset by design (a stopping process never recovers); other tests in this class do not depend on it.
    }

    @Test
    void metricsUseRouteTemplatesAndSharedNames() throws Exception {
        mvc.perform(get("/payments/aaa"));
        mvc.perform(get("/payments/bbb"));
        mvc.perform(get("/something/else"));
        String text = mvc.perform(get("/metrics")).andExpect(status().isOk()).andReturn().getResponse().getContentAsString();
        assertThat(text).contains("http_requests_total{method=\"GET\",route=\"/payments/{id}\",service=\"payments\",status=\"404\"}");
        assertThat(text).contains("route=\"unmatched\"");
        assertThat(text).doesNotContain("/payments/aaa");
        assertThat(text).contains("http_request_duration_seconds_bucket{", "le=\"0.005\"", "http_requests_in_flight{service=\"payments\"}");
    }
}
