package com.kestrel.settlement.api.service;

import com.kestrel.settlement.core.EntryType;
import com.kestrel.settlement.core.LedgerEntry;
import com.kestrel.settlement.core.LedgerEntryRepository;
import java.time.Instant;
import java.util.List;
import java.util.Optional;
import java.util.UUID;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.data.domain.Limit;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
public class LedgerService {

    private static final Logger log = LoggerFactory.getLogger(LedgerService.class);

    private final LedgerEntryRepository repository;

    public LedgerService(LedgerEntryRepository repository) {
        this.repository = repository;
    }

    /** Result of a write: the entry, plus whether this call is the one that created it. */
    public record Recorded(LedgerEntry entry, boolean created) {}

    /**
     * Idempotent write. Retried payment webhooks are a fact of life, so the same
     * idempotency key must never produce a second movement of money.
     */
    @Transactional
    public Recorded record(
            String accountId,
            EntryType entryType,
            long amountMinor,
            String currency,
            String idempotencyKey,
            String batchId) {

        String key = normalise(idempotencyKey);
        if (key != null) {
            Optional<LedgerEntry> existing = repository.findByIdempotencyKey(key);
            if (existing.isPresent()) {
                log.info("idempotent replay for key={} accountId={}", key, accountId);
                return new Recorded(existing.get(), false);
            }
        }

        LedgerEntry entry = new LedgerEntry(
                UUID.randomUUID(), accountId, entryType, amountMinor, currency, key, normalise(batchId), Instant.now());

        try {
            return new Recorded(repository.saveAndFlush(entry), true);
        } catch (DataIntegrityViolationException ex) {
            // Two concurrent replays of the same key. The database is the arbiter.
            if (key == null) {
                throw ex;
            }
            LedgerEntry winner = repository
                    .findByIdempotencyKey(key)
                    .orElseThrow(() -> ex);
            log.info("lost the idempotency race for key={}, returning the winning entry", key);
            return new Recorded(winner, false);
        }
    }

    @Transactional(readOnly = true)
    public List<LedgerEntry> recent(String accountId, int limit) {
        Limit cap = Limit.of(Math.clamp(limit, 1, 500));
        return accountId == null || accountId.isBlank()
                ? repository.findAllByOrderByCreatedAtDesc(cap)
                : repository.findByAccountIdOrderByCreatedAtDesc(accountId, cap);
    }

    @Transactional(readOnly = true)
    public long balanceMinor(String accountId) {
        return repository.balanceMinorFor(accountId);
    }

    @Transactional(readOnly = true)
    public long countInBatch(String batchId) {
        return repository.countByBatchId(batchId);
    }

    private static String normalise(String value) {
        return value == null || value.isBlank() ? null : value.trim();
    }
}
