package dev.mcsre.payments.data;

/** The database could not serve a request. Mapped to HTTP 503 so callers can retry with the same key. */
public class StorageUnavailableException extends RuntimeException {

    public StorageUnavailableException(String message, Throwable cause) {
        super(message, cause);
    }
}
