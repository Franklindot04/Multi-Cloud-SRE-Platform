package dev.mcsre.payments.domain;

import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.Set;

/**
 * Deterministic approval rules for the simulation. The same request always gets the same decision.
 *
 * <ol>
 *   <li>A currency outside the allowed set is declined (currency_not_supported).
 *   <li>An amount above the limit is declined (amount_exceeds_limit).
 *   <li>Otherwise the order ID is hashed to a number in [0, 1); at or above the approval ratio the
 *       payment is declined (issuer_declined). A ratio of 1.0 approves everything, 0.0 declines everything.
 * </ol>
 */
public final class DecisionPolicy {

    /** The decision for one request. */
    public record Decision(Payment.Status status, String declineReason) {
        public static Decision approved() {
            return new Decision(Payment.Status.APPROVED, null);
        }

        public static Decision declined(String reason) {
            return new Decision(Payment.Status.DECLINED, reason);
        }
    }

    private final long declineAboveMinor;
    private final double approvalRatio;
    private final Set<String> allowedCurrencies;

    public DecisionPolicy(long declineAboveMinor, double approvalRatio, Set<String> allowedCurrencies) {
        this.declineAboveMinor = declineAboveMinor;
        this.approvalRatio = approvalRatio;
        this.allowedCurrencies = Set.copyOf(allowedCurrencies);
    }

    public Decision decide(String orderId, long amountMinor, String currency) {
        if (!allowedCurrencies.contains(currency)) {
            return Decision.declined("currency_not_supported");
        }
        if (amountMinor > declineAboveMinor) {
            return Decision.declined("amount_exceeds_limit");
        }
        if (fraction(orderId) >= approvalRatio) {
            return Decision.declined("issuer_declined");
        }
        return Decision.approved();
    }

    /** Maps a string to a stable number in [0, 1). */
    static double fraction(String value) {
        try {
            byte[] digest = MessageDigest.getInstance("SHA-256").digest(value.getBytes(StandardCharsets.UTF_8));
            long bits = ByteBuffer.wrap(digest).getLong() >>> 11; // 53 random bits
            return bits / (double) (1L << 53);
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException("SHA-256 is not available", e);
        }
    }
}
