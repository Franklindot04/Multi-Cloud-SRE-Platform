package dev.mcsre.payments.obs;

import java.util.concurrent.atomic.AtomicBoolean;

/** Set when the process is asked to stop, so /readyz fails before the listener closes. */
public final class Drain {

    private final AtomicBoolean draining = new AtomicBoolean();

    public void start() {
        draining.set(true);
    }

    public boolean isDraining() {
        return draining.get();
    }
}
