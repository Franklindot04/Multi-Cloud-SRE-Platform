package dev.mcsre.payments.domain;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.time.Instant;
import org.junit.jupiter.api.Test;

class InMemoryPaymentRepositoryTest {

    private static Payment payment(String id) {
        return new Payment(id, "o", 100, "USD", Payment.Status.APPROVED, null, Instant.EPOCH);
    }

    @Test
    void storesOncePerKey() {
        InMemoryPaymentRepository repo = new InMemoryPaymentRepository(10);
        PaymentRepository.Stored first = repo.saveIfAbsent("k", "fp", () -> payment("a"));
        PaymentRepository.Stored second = repo.saveIfAbsent("k", "fp", () -> payment("b"));
        assertThat(first.created()).isTrue();
        assertThat(second.created()).isFalse();
        assertThat(second.payment().id()).isEqualTo("a");
    }

    @Test
    void doesNotBuildAPaymentForAReplay() {
        InMemoryPaymentRepository repo = new InMemoryPaymentRepository(10);
        repo.saveIfAbsent("k", "fp", () -> payment("a"));
        repo.saveIfAbsent("k", "fp", () -> {
            throw new AssertionError("the supplier must not run for a replay");
        });
    }

    @Test
    void mismatchedFingerprintIsRejected() {
        InMemoryPaymentRepository repo = new InMemoryPaymentRepository(10);
        repo.saveIfAbsent("k", "fp-1", () -> payment("a"));
        assertThatThrownBy(() -> repo.saveIfAbsent("k", "fp-2", () -> payment("b")))
                .isInstanceOf(PaymentRepository.KeyMismatchException.class);
    }

    @Test
    void oldestEntriesAreEvicted() {
        InMemoryPaymentRepository repo = new InMemoryPaymentRepository(2);
        for (String id : new String[] {"a", "b", "c"}) {
            repo.saveIfAbsent("k-" + id, "fp", () -> payment(id));
        }
        assertThat(repo.findById("a")).isEmpty();
        assertThat(repo.findById("c")).isPresent();
        assertThat(repo.saveIfAbsent("k-a", "fp", () -> payment("a2")).created()).isTrue();
    }
}
