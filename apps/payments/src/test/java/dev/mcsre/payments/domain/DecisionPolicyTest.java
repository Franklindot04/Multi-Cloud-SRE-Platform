package dev.mcsre.payments.domain;

import static org.assertj.core.api.Assertions.assertThat;

import java.util.Set;
import org.junit.jupiter.api.Test;

class DecisionPolicyTest {

    private static DecisionPolicy policy(double ratio) {
        return new DecisionPolicy(10_000, ratio, Set.of("USD", "EUR"));
    }

    @Test
    void approvesAmountsWithinTheLimit() {
        assertThat(policy(1.0).decide("o-1", 10_000, "USD").status()).isEqualTo(Payment.Status.APPROVED);
    }

    @Test
    void declinesAmountsAboveTheLimit() {
        DecisionPolicy.Decision d = policy(1.0).decide("o-1", 10_001, "USD");
        assertThat(d.status()).isEqualTo(Payment.Status.DECLINED);
        assertThat(d.declineReason()).isEqualTo("amount_exceeds_limit");
    }

    @Test
    void declinesUnsupportedCurrencies() {
        DecisionPolicy.Decision d = policy(1.0).decide("o-1", 100, "JPY");
        assertThat(d.declineReason()).isEqualTo("currency_not_supported");
    }

    @Test
    void currencyIsCheckedBeforeAmount() {
        assertThat(policy(1.0).decide("o-1", 999_999, "JPY").declineReason()).isEqualTo("currency_not_supported");
    }

    @Test
    void ratioOfOneApprovesEverythingAndZeroDeclinesEverything() {
        for (int i = 0; i < 200; i++) {
            assertThat(policy(1.0).decide("order-" + i, 100, "USD").status()).isEqualTo(Payment.Status.APPROVED);
            DecisionPolicy.Decision d = policy(0.0).decide("order-" + i, 100, "USD");
            assertThat(d.declineReason()).isEqualTo("issuer_declined");
        }
    }

    @Test
    void decisionsAreDeterministicPerOrder() {
        DecisionPolicy half = policy(0.5);
        for (int i = 0; i < 100; i++) {
            String id = "order-" + i;
            assertThat(half.decide(id, 100, "USD")).isEqualTo(half.decide(id, 100, "USD"));
        }
    }

    @Test
    void aRatioOfAboutHalfApprovesAboutHalf() {
        DecisionPolicy half = policy(0.5);
        long approved = java.util.stream.IntStream.range(0, 2000)
                .filter(i -> half.decide("order-" + i, 100, "USD").status() == Payment.Status.APPROVED)
                .count();
        assertThat(approved).isBetween(850L, 1150L);
    }

    @Test
    void fractionIsAlwaysInTheUnitInterval() {
        for (int i = 0; i < 500; i++) {
            assertThat(DecisionPolicy.fraction("x" + i)).isGreaterThanOrEqualTo(0.0).isLessThan(1.0);
        }
    }
}
