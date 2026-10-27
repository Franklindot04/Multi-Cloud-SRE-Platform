package dev.mcsre.payments.web;

import dev.mcsre.payments.domain.AuthorizationService;
import dev.mcsre.payments.domain.AuthorizeRequest;
import dev.mcsre.payments.domain.Payment;
import dev.mcsre.payments.domain.PaymentRepository;
import java.util.regex.Pattern;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class PaymentsController {

    private static final Pattern IDEMPOTENCY_KEY = Pattern.compile("^[\\x21-\\x7e]{1,128}$");

    private final AuthorizationService service;

    public PaymentsController(AuthorizationService service) {
        this.service = service;
    }

    @PostMapping("/payments/authorize")
    public ResponseEntity<Payment> authorize(
            @RequestHeader(value = "Idempotency-Key", required = false) String key,
            @RequestBody AuthorizeRequest request) {
        if (key == null || !IDEMPOTENCY_KEY.matcher(key).matches()) {
            throw new ApiException(
                    HttpStatus.BAD_REQUEST,
                    "missing_idempotency_key",
                    "Idempotency-Key header is required (1-128 printable characters)");
        }
        String problem = request.validate();
        if (problem != null) {
            throw new ApiException(HttpStatus.UNPROCESSABLE_ENTITY, "validation_error", problem);
        }
        try {
            AuthorizationService.Result result = service.authorize(key, request);
            return ResponseEntity.status(result.created() ? HttpStatus.CREATED : HttpStatus.OK).body(result.payment());
        } catch (PaymentRepository.KeyMismatchException e) {
            throw new ApiException(
                    HttpStatus.UNPROCESSABLE_ENTITY,
                    "idempotency_key_mismatch",
                    "this Idempotency-Key was used with a different request body");
        }
    }

    @GetMapping("/payments/{id}")
    public Payment get(@PathVariable String id) {
        return service.find(id).orElseThrow(() -> new ApiException(HttpStatus.NOT_FOUND, "not_found", "payment not found"));
    }
}
