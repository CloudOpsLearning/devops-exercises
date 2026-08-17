package com.kestrel.settlement.api.web;

import com.kestrel.settlement.api.service.LedgerService;
import com.kestrel.settlement.api.web.LedgerDtos.BalanceResponse;
import com.kestrel.settlement.api.web.LedgerDtos.CreateEntryRequest;
import com.kestrel.settlement.api.web.LedgerDtos.EntryResponse;
import jakarta.validation.Valid;
import java.math.BigDecimal;
import java.util.List;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/v1")
public class LedgerController {

    private final LedgerService ledger;

    public LedgerController(LedgerService ledger) {
        this.ledger = ledger;
    }

    @PostMapping("/entries")
    public ResponseEntity<EntryResponse> create(@Valid @RequestBody CreateEntryRequest request) {
        LedgerService.Recorded recorded = ledger.record(
                request.accountId(),
                request.entryType(),
                request.amountMinor(),
                request.currency(),
                request.idempotencyKey(),
                request.batchId());

        EntryResponse body = EntryResponse.of(recorded.entry(), recorded.created());
        return ResponseEntity.status(recorded.created() ? HttpStatus.CREATED : HttpStatus.OK).body(body);
    }

    @GetMapping("/entries")
    public List<EntryResponse> list(
            @RequestParam(required = false) String accountId,
            @RequestParam(defaultValue = "25") int limit) {
        return ledger.recent(accountId, limit).stream()
                .map(entry -> EntryResponse.of(entry, false))
                .toList();
    }

    @GetMapping("/accounts/{accountId}/balance")
    public BalanceResponse balance(@PathVariable String accountId) {
        long minor = ledger.balanceMinor(accountId);
        return new BalanceResponse(accountId, minor, BigDecimal.valueOf(minor, 2), "EUR");
    }

    @GetMapping("/batches/{batchId}/count")
    public BalanceResponse batchCount(@PathVariable String batchId) {
        long count = ledger.countInBatch(batchId);
        return new BalanceResponse(batchId, count, BigDecimal.valueOf(count), "count");
    }
}
