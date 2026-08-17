package com.kestrel.settlement.api.service;

import com.kestrel.settlement.core.EntryType;
import java.util.UUID;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;

/**
 * A settlement run is the operation nobody may interrupt.
 *
 * It holds a request open while it talks to the payout provider, and only then writes
 * the ledger entry. If the process is killed mid-run, the money moved at the provider
 * and no row exists on our side - the exact class of break the finance team spent a
 * weekend reconciling by hand.
 */
@Service
public class SettlementRunService {

    private static final Logger log = LoggerFactory.getLogger(SettlementRunService.class);
    private static final long STEP_MILLIS = 250;

    private final LedgerService ledger;

    public SettlementRunService(LedgerService ledger) {
        this.ledger = ledger;
    }

    public record Result(String batchId, int seconds, long durationMs, String entryId) {}

    public Result run(int seconds, String requestedBatchId) {
        String batchId = requestedBatchId == null || requestedBatchId.isBlank()
                ? "batch-" + UUID.randomUUID().toString().substring(0, 8)
                : requestedBatchId.trim();

        long startedAt = System.nanoTime();
        log.info("settlement run started batchId={} holdSeconds={}", batchId, seconds);

        long steps = Math.max(0, (seconds * 1000L) / STEP_MILLIS);
        for (long step = 0; step < steps; step++) {
            try {
                Thread.sleep(STEP_MILLIS);
            } catch (InterruptedException ex) {
                Thread.currentThread().interrupt();
                log.warn("settlement run interrupted batchId={} afterMs={}", batchId, step * STEP_MILLIS);
                throw new IllegalStateException("settlement run was interrupted before the ledger was written", ex);
            }
        }

        LedgerService.Recorded recorded = ledger.record(
                "ACC-" + batchId.hashCode(), EntryType.CREDIT, 125_00L, "EUR", "settlement:" + batchId, batchId);

        long durationMs = (System.nanoTime() - startedAt) / 1_000_000;
        log.info(
                "settlement run committed batchId={} entryId={} durationMs={}",
                batchId,
                recorded.entry().getId(),
                durationMs);

        return new Result(batchId, seconds, durationMs, recorded.entry().getId().toString());
    }
}
