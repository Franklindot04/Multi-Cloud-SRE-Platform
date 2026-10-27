package dev.mcsre.payments.obs;

import jakarta.servlet.http.HttpServletRequest;

/** Access to the request ID chosen by the filter. */
public final class RequestIds {

    public static final String ATTRIBUTE = RequestIds.class.getName() + ".id";

    private RequestIds() {}

    public static String of(HttpServletRequest request) {
        Object id = request.getAttribute(ATTRIBUTE);
        return id == null ? "" : id.toString();
    }
}
