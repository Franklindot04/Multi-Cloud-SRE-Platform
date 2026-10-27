package dev.mcsre.payments.domain;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import org.junit.jupiter.api.Test;

class AuthorizationServiceTest {

    private final Clock clock = Clock.fixed(Instant.parse("2026-01-02T03:04:05Z"), ZoneOffset.UTC);

    private AuthorizationService service(long limit, double ratio) {
        return new AuthorizationService(
                new InMemoryPaymentRepository(1000), new DecisionPolicy(limit, ratio, Set.of("USD")), clock);
    }

    private static AuthorizeRequest request(long amount) {
        return new AuthorizeRequest("order-1", amount, "USD");
    }

    @Test
    void approvesAndRecordsThePayment() {
        AuthorizationService.Result r = service(10_000, 1.0).authorize("k1", request(2500));
        assertThat(r.created()).isTrue();
        assertThat(r.payment().status()).isEqualTo(Payment.Status.APPROVED);
        assertThat(r.payment().createdAt()).isEqualTo(Instant.parse("2026-01-02T03:04:05Z"));
        assertThat(r.payment().declineReason()).isNull();
    }

    @Test
    void declinesAboveTheLimit() {
        AuthorizationService.Result r = service(1000, 1.0).authorize("k1", request(1001));
        assertThat(r.payment().status()).isEqualTo(Payment.Status.DECLINED);
        assertThat(r.payment().declineReason()).isEqualTo("amount_exceeds_limit");
    }

    @Test
    void sameKeyAndBodyReturnsTheSameResult() {
        AuthorizationService s = service(10_000, 1.0);
        AuthorizationService.Result first = s.authorize("k1", request(2500));
        AuthorizationService.Result second = s.authorize("k1", request(2500));
        assertThat(second.created()).isFalse();
        assertThat(second.payment()).isEqualTo(first.payment());
    }

    @Test
    void aDeclineIsAlsoReplayedUnchanged() {
        AuthorizationService s = service(1000, 1.0);
        Payment first = s.authorize("k1", request(5000)).payment();
        assertThat(s.authorize("k1", request(5000)).payment()).isEqualTo(first);
    }

    @Test
    void sameKeyWithADifferentBodyIsRejected() {
        AuthorizationService s = service(10_000, 1.0);
        s.authorize("k1", request(2500));
        assertThatThrownBy(() -> s.authorize("k1", request(2600)))
                .isInstanceOf(PaymentRepository.KeyMismatchException.class);
    }

    @Test
    void differentKeysCreateDifferentPayments() {
        AuthorizationService s = service(10_000, 1.0);
        Payment a = s.authorize("k1", request(100)).payment();
        Payment b = s.authorize("k2", request(100)).payment();
        assertThat(a.id()).isNotEqualTo(b.id());
    }

    @Test
    void paymentsCanBeFoundById() {
        AuthorizationService s = service(10_000, 1.0);
        Payment p = s.authorize("k1", request(100)).payment();
        assertThat(s.find(p.id())).contains(p);
        assertThat(s.find("missing")).isEmpty();
    }

    @Test
    void concurrentRequestsWithOneKeyCreateExactlyOnePayment() throws Exception {
        AuthorizationService s = service(10_000, 1.0);
        int threads = 24;
        ExecutorService pool = Executors.newFixedThreadPool(threads);
        CountDownLatch go = new CountDownLatch(1);
        Set<String> ids = ConcurrentHashMap.newKeySet();
        Set<Boolean> createdFlags = ConcurrentHashMap.newKeySet();
        java.util.concurrent.atomic.AtomicInteger created = new java.util.concurrent.atomic.AtomicInteger();
        for (int i = 0; i < threads; i++) {
            pool.submit(() -> {
                go.await();
                AuthorizationService.Result r = s.authorize("same-key", request(100));
                ids.add(r.payment().id());
                createdFlags.add(r.created());
                if (r.created()) {
                    created.incrementAndGet();
                }
                return null;
            });
        }
        go.countDown();
        pool.shutdown();
        assertThat(pool.awaitTermination(10, TimeUnit.SECONDS)).isTrue();
        assertThat(ids).hasSize(1);
        assertThat(created.get()).isEqualTo(1);
    }
}
