package dev.mcsre.payments.domain;

import java.util.HashMap;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Optional;
import java.util.function.Supplier;

/** Thread-safe in-memory repository holding at most {@code max} payments (oldest dropped first). */
public final class InMemoryPaymentRepository implements PaymentRepository {

    private record Entry(String fingerprint, Payment payment) {}

    private final int max;
    private final Map<String, Entry> byKey = new LinkedHashMap<>();
    private final Map<String, String> keyById = new HashMap<>();

    public InMemoryPaymentRepository(int max) {
        this.max = max;
    }

    @Override
    public synchronized Stored saveIfAbsent(String key, String fingerprint, Supplier<Payment> create) {
        Entry existing = byKey.get(key);
        if (existing != null) {
            if (!existing.fingerprint().equals(fingerprint)) {
                throw new KeyMismatchException(key);
            }
            return new Stored(existing.payment(), false);
        }
        Payment payment = create.get();
        byKey.put(key, new Entry(fingerprint, payment));
        keyById.put(payment.id(), key);
        while (byKey.size() > max) {
            Iterator<Map.Entry<String, Entry>> oldest = byKey.entrySet().iterator();
            Map.Entry<String, Entry> evicted = oldest.next();
            oldest.remove();
            keyById.remove(evicted.getValue().payment().id());
        }
        return new Stored(payment, true);
    }

    @Override
    public synchronized Optional<Payment> findById(String id) {
        String key = keyById.get(id);
        return key == null ? Optional.empty() : Optional.of(byKey.get(key).payment());
    }
}
