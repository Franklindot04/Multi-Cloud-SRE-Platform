package dev.mcsre.payments.domain;

import io.opentelemetry.api.common.AttributeKey;
import io.opentelemetry.api.trace.Span;
import io.opentelemetry.api.trace.Tracer;
import io.opentelemetry.api.trace.TracerProvider;
import io.opentelemetry.context.Scope;
import java.time.Clock;
import java.time.Instant;
import java.util.UUID;

/** Authorizes simulated payments with strict idempotency: the same key always returns the same result. */
public final class AuthorizationService {

    /** The payment and whether this call created it (false for a replay). */
    public record Result(Payment payment, boolean created) {}

    private final PaymentRepository repository;
    private final DecisionPolicy policy;
    private final Clock clock;
    private final Tracer tracer;

    public AuthorizationService(PaymentRepository repository, DecisionPolicy policy, Clock clock) {
        this(repository, policy, clock, TracerProvider.noop().get("payments"));
    }

    public AuthorizationService(PaymentRepository repository, DecisionPolicy policy, Clock clock, Tracer tracer) {
        this.repository = repository;
        this.policy = policy;
        this.clock = clock;
        this.tracer = tracer;
    }

    public Result authorize(String idempotencyKey, AuthorizeRequest request) {
        PaymentRepository.Stored stored = repository.saveIfAbsent(idempotencyKey, request.fingerprint(), () -> {
            DecisionPolicy.Decision decision = decide(request);
            return new Payment(
                    UUID.randomUUID().toString(),
                    request.orderId(),
                    request.amountMinor(),
                    request.currency(),
                    decision.status(),
                    decision.declineReason(),
                    Instant.now(clock));
        });
        return new Result(stored.payment(), stored.created());
    }

    /**
     * The authorization decision, in its own span. It is only taken for a key that is new, so a replay has none. The
     * attributes are the outcome and the reason code, which are fixed words; there is no order, amount, currency or
     * customer data.
     */
    private DecisionPolicy.Decision decide(AuthorizeRequest request) {
        Span span = tracer.spanBuilder("payments.decide").startSpan();
        try (Scope ignored = span.makeCurrent()) {
            DecisionPolicy.Decision decision = policy.decide(request.orderId(), request.amountMinor(), request.currency());
            span.setAttribute(AttributeKey.stringKey("payments.decision"), decision.status().wire());
            if (decision.declineReason() != null) {
                span.setAttribute(AttributeKey.stringKey("payments.decline_reason"), decision.declineReason());
            }
            return decision;
        } finally {
            span.end();
        }
    }

    public java.util.Optional<Payment> find(String id) {
        return repository.findById(id);
    }
}
