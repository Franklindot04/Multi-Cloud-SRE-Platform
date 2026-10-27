package dev.mcsre.payments.domain;

import com.fasterxml.jackson.annotation.JsonInclude;
import com.fasterxml.jackson.annotation.JsonProperty;
import java.time.Instant;

/** A simulated payment authorization result. */
@JsonInclude(JsonInclude.Include.ALWAYS)
public record Payment(
        String id,
        @JsonProperty("order_id") String orderId,
        @JsonProperty("amount_minor") long amountMinor,
        String currency,
        Status status,
        @JsonProperty("decline_reason") String declineReason,
        @JsonProperty("created_at") Instant createdAt) {

    /** Outcome of an authorization. */
    public enum Status {
        APPROVED("approved"),
        DECLINED("declined");

        private final String wire;

        Status(String wire) {
            this.wire = wire;
        }

        @com.fasterxml.jackson.annotation.JsonValue
        public String wire() {
            return wire;
        }
    }
}
