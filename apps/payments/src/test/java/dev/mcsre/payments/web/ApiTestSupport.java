package dev.mcsre.payments.web;

import dev.mcsre.payments.obs.ObservabilityFilter;
import org.springframework.boot.web.servlet.FilterRegistrationBean;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;
import org.springframework.web.context.WebApplicationContext;

final class ApiTestSupport {

    static final String BODY = "{\"order_id\":\"order-1\",\"amount_minor\":2500,\"currency\":\"USD\"}";

    private ApiTestSupport() {}

    static MockMvc mockMvc(WebApplicationContext context, FilterRegistrationBean<ObservabilityFilter> filter) {
        return MockMvcBuilders.webAppContextSetup(context).addFilters(filter.getFilter()).build();
    }
}
