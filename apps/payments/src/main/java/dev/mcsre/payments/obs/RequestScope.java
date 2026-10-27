package dev.mcsre.payments.obs;

/**
 * The request ID and trace ID of the request being handled on this thread, so code below the web
 * layer (the database repository) can put them in its log lines.
 */
public final class RequestScope {

    private static final ThreadLocal<String[]> CURRENT = new ThreadLocal<>();

    private RequestScope() {}

    public static void enter(String requestId, String traceId) {
        CURRENT.set(new String[] {requestId, traceId});
    }

    public static void leave() {
        CURRENT.remove();
    }

    public static String requestId() {
        String[] current = CURRENT.get();
        return current == null ? "" : current[0];
    }

    public static String traceId() {
        String[] current = CURRENT.get();
        return current == null ? "" : current[1];
    }
}
