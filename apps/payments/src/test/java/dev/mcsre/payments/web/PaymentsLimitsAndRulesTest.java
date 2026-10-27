package dev.mcsre.payments.web;

import static dev.mcsre.payments.web.ApiTestSupport.BODY;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import dev.mcsre.payments.obs.ObservabilityFilter;
import org.junit.jupiter.api.Nested;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.web.servlet.FilterRegistrationBean;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.web.context.WebApplicationContext;

class PaymentsLimitsAndRulesTest {

    @Nested
    @SpringBootTest(properties = {"MAX_BODY_BYTES=60"})
    class BodyLimit {
        @Autowired WebApplicationContext context;
        @Autowired FilterRegistrationBean<ObservabilityFilter> filter;

        @Test
        void oversizedBodiesAre413WhetherOrNotLengthIsDeclared() throws Exception {
            MockMvc mvc = ApiTestSupport.mockMvc(context, filter);
            mvc.perform(post("/payments/authorize").header("Idempotency-Key", "k").contentType(MediaType.APPLICATION_JSON).content(BODY + " ".repeat(100)))
                    .andExpect(status().isPayloadTooLarge())
                    .andExpect(jsonPath("$.error.code").value("payload_too_large"));
            mvc.perform(post("/payments/authorize")
                            .header("Idempotency-Key", "k2")
                            .contentType(MediaType.APPLICATION_JSON)
                            .content(BODY + " ".repeat(100))
                            .with(request -> {
                                request.removeHeader("Content-Length");
                                return request;
                            }))
                    .andExpect(status().isPayloadTooLarge());
        }
    }

    @Nested
    @SpringBootTest(properties = {"PAYMENT_APPROVAL_RATIO=0.0"})
    class ApprovalRatio {
        @Autowired WebApplicationContext context;
        @Autowired FilterRegistrationBean<ObservabilityFilter> filter;

        @Test
        void aRatioOfZeroDeclinesEverythingAsIssuerDeclined() throws Exception {
            MockMvc mvc = ApiTestSupport.mockMvc(context, filter);
            mvc.perform(post("/payments/authorize").header("Idempotency-Key", "k").contentType(MediaType.APPLICATION_JSON).content(BODY))
                    .andExpect(status().isCreated())
                    .andExpect(jsonPath("$.status").value("declined"))
                    .andExpect(jsonPath("$.decline_reason").value("issuer_declined"));
        }
    }

    @Nested
    @SpringBootTest(properties = {"PAYMENT_ALLOWED_CURRENCIES=EUR"})
    class Currencies {
        @Autowired WebApplicationContext context;
        @Autowired FilterRegistrationBean<ObservabilityFilter> filter;

        @Test
        void unsupportedCurrenciesAreDeclined() throws Exception {
            MockMvc mvc = ApiTestSupport.mockMvc(context, filter);
            mvc.perform(post("/payments/authorize").header("Idempotency-Key", "k").contentType(MediaType.APPLICATION_JSON).content(BODY))
                    .andExpect(jsonPath("$.decline_reason").value("currency_not_supported"));
        }
    }
}
