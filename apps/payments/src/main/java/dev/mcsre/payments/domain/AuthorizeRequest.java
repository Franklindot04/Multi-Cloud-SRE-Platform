package dev.mcsre.payments.domain;

import com.fasterxml.jackson.annotation.JsonProperty;

/** Body of POST /payments/authorize. Fields are nullable so validation can report them. */
public record AuthorizeRequest(
        @JsonProperty("order_id") String orderId,
        @JsonProperty("amount_minor") Long amountMinor,
        String currency) {

    /** Returns a message describing the first problem, or null when the request is valid. */
    public String validate() {
        if (orderId == null || orderId.isBlank() || orderId.length() > 64) {
            return "order_id must be 1-64 characters";
        }
        if (amountMinor == null || amountMinor < 1) {
            return "amount_minor must be a positive integer";
        }
        if (currency == null || !currency.matches("[A-Z]{3}")) {
            return "currency must be a 3-letter upper-case code";
        }
        return null;
    }

    /** Stable description of the request, used to detect an idempotency key reused with another body. */
    public String fingerprint() {
        return orderId + "|" + amountMinor + "|" + currency;
    }
}
