package dev.mcsre.payments.domain;

import java.util.Optional;
import java.util.function.Supplier;

/** Payment storage. A database can implement this without changing the service or the handlers. */
public interface PaymentRepository {

    /** Result of {@link #saveIfAbsent}. */
    record Stored(Payment payment, boolean created) {}

    /** The idempotency key was already used with a different request. */
    class KeyMismatchException extends RuntimeException {
        public KeyMismatchException(String key) {
            super("idempotency key already used with a different request: " + key);
        }
    }

    /**
     * Stores the payment built by the supplier under the key unless the key exists. The supplier runs
     * only when a payment is created. Throws {@link KeyMismatchException} if the key exists with a
     * different fingerprint.
     */
    Stored saveIfAbsent(String key, String fingerprint, Supplier<Payment> create);

    Optional<Payment> findById(String id);
}
