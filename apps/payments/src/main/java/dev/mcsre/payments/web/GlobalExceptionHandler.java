package dev.mcsre.payments.web;

import dev.mcsre.payments.data.StorageUnavailableException;
import dev.mcsre.payments.obs.ErrorJson;
import dev.mcsre.payments.obs.ObservabilityFilter;
import dev.mcsre.payments.obs.RequestIds;
import dev.mcsre.payments.obs.Tracing;
import jakarta.servlet.http.HttpServletRequest;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.HttpMediaTypeNotSupportedException;
import org.springframework.web.HttpRequestMethodNotSupportedException;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;
import org.springframework.web.servlet.resource.NoResourceFoundException;
import org.springframework.http.converter.HttpMessageNotReadableException;

/** Maps every failure to the shared error envelope. */
@RestControllerAdvice
public class GlobalExceptionHandler {

    @ExceptionHandler(ApiException.class)
    ResponseEntity<String> api(ApiException e, HttpServletRequest request) {
        return body(e.status(), e.code(), e.getMessage(), request);
    }

    @ExceptionHandler(HttpMessageNotReadableException.class)
    ResponseEntity<String> unreadable(HttpMessageNotReadableException e, HttpServletRequest request) {
        for (Throwable t = e; t != null; t = t.getCause()) {
            if (t instanceof ObservabilityFilter.PayloadTooLargeException) {
                return body(HttpStatus.PAYLOAD_TOO_LARGE, "payload_too_large", "request body is too large", request);
            }
        }
        return body(HttpStatus.BAD_REQUEST, "invalid_json", "request body is not valid JSON for this endpoint", request);
    }

    @ExceptionHandler(ObservabilityFilter.PayloadTooLargeException.class)
    ResponseEntity<String> tooLarge(HttpServletRequest request) {
        return body(HttpStatus.PAYLOAD_TOO_LARGE, "payload_too_large", "request body is too large", request);
    }

    @ExceptionHandler(HttpRequestMethodNotSupportedException.class)
    ResponseEntity<String> wrongMethod(HttpServletRequest request) {
        return body(HttpStatus.METHOD_NOT_ALLOWED, "method_not_allowed", "method not allowed", request);
    }

    @ExceptionHandler(HttpMediaTypeNotSupportedException.class)
    ResponseEntity<String> wrongMediaType(HttpServletRequest request) {
        return body(HttpStatus.UNSUPPORTED_MEDIA_TYPE, "unsupported_media_type", "use Content-Type: application/json", request);
    }

    @ExceptionHandler(NoResourceFoundException.class)
    ResponseEntity<String> notFound(HttpServletRequest request) {
        return body(HttpStatus.NOT_FOUND, "not_found", "not found", request);
    }

    @ExceptionHandler(StorageUnavailableException.class)
    ResponseEntity<String> storageUnavailable(StorageUnavailableException e, HttpServletRequest request) {
        Tracing.recordFailure(e);
        return body(HttpStatus.SERVICE_UNAVAILABLE, "unavailable", "storage is temporarily unavailable", request);
    }

    @ExceptionHandler(Exception.class)
    ResponseEntity<String> other(Exception e, HttpServletRequest request) {
        Tracing.recordFailure(e);
        return body(HttpStatus.INTERNAL_SERVER_ERROR, "internal_error", "internal error", request);
    }

    private static ResponseEntity<String> body(HttpStatus status, String code, String message, HttpServletRequest request) {
        return ResponseEntity.status(status)
                .contentType(MediaType.APPLICATION_JSON)
                .body(ErrorJson.of(code, message, RequestIds.of(request)));
    }
}
