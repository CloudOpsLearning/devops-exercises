package com.kestrel.settlement.api.web;

import com.kestrel.settlement.api.web.LedgerDtos.ErrorResponse;
import java.util.List;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.MethodArgumentNotValidException;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;

@RestControllerAdvice
public class ApiErrorHandler {

    private static final Logger log = LoggerFactory.getLogger(ApiErrorHandler.class);

    @ExceptionHandler(MethodArgumentNotValidException.class)
    ResponseEntity<ErrorResponse> onInvalid(MethodArgumentNotValidException ex) {
        List<String> details = ex.getBindingResult().getFieldErrors().stream()
                .map(error -> error.getField() + " " + error.getDefaultMessage())
                .toList();
        return ResponseEntity.badRequest().body(new ErrorResponse("invalid_request", "request validation failed", details));
    }

    @ExceptionHandler(IllegalArgumentException.class)
    ResponseEntity<ErrorResponse> onIllegalArgument(IllegalArgumentException ex) {
        return ResponseEntity.badRequest().body(new ErrorResponse("invalid_request", ex.getMessage(), List.of()));
    }

    @ExceptionHandler(OutOfMemoryError.class)
    ResponseEntity<ErrorResponse> onOutOfMemory(OutOfMemoryError error) {
        // Logged loudly on purpose: this is the line an operator needs to find.
        log.error(
                "OutOfMemoryError while serving a request: maxHeapMb={} - the heap ceiling and the container limit disagree",
                Runtime.getRuntime().maxMemory() / (1024 * 1024),
                error);
        return ResponseEntity.status(HttpStatus.INSUFFICIENT_STORAGE)
                .body(new ErrorResponse("out_of_memory", "the JVM heap ceiling was reached", List.of()));
    }

    @ExceptionHandler(Exception.class)
    ResponseEntity<ErrorResponse> onUnexpected(Exception ex) {
        log.error("unhandled failure: {}", ex.getMessage(), ex);
        return ResponseEntity.internalServerError()
                .body(new ErrorResponse("internal_error", String.valueOf(ex.getMessage()), List.of()));
    }
}
