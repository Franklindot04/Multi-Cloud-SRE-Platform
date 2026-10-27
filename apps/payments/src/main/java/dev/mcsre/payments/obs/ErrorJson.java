package dev.mcsre.payments.obs;

import java.util.LinkedHashMap;
import java.util.Map;

/** The error envelope shared by every service. */
public final class ErrorJson {

    private ErrorJson() {}

    public static String of(String code, String message, String requestId) {
        Map<String, Object> inner = new LinkedHashMap<>();
        inner.put("code", code);
        inner.put("message", message);
        inner.put("request_id", requestId);
        return "{\"error\":" + JsonLog.toJson(inner) + "}";
    }
}
