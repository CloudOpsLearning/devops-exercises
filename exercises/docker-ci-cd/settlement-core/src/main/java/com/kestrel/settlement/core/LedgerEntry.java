package com.kestrel.settlement.core;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.EnumType;
import jakarta.persistence.Enumerated;
import jakarta.persistence.Id;
import jakarta.persistence.Table;
import java.math.BigDecimal;
import java.time.Instant;
import java.util.UUID;

/**
 * One immutable movement on a driver's settlement account.
 *
 * Rows are never updated and never deleted: corrections are new entries in the
 * opposite direction. The finance team reconciles against this table directly,
 * which is why the schema is owned by a migration and not by Hibernate.
 */
@Entity
@Table(name = "ledger_entries")
public class LedgerEntry {

    @Id
    @Column(name = "id", nullable = false, updatable = false)
    private UUID id;

    @Column(name = "account_id", nullable = false, length = 64)
    private String accountId;

    @Enumerated(EnumType.STRING)
    @Column(name = "entry_type", nullable = false, length = 16)
    private EntryType entryType;

    @Column(name = "amount_minor", nullable = false)
    private long amountMinor;

    @Column(name = "currency", nullable = false, length = 3)
    private String currency;

    @Column(name = "idempotency_key", length = 128)
    private String idempotencyKey;

    @Column(name = "batch_id", length = 64)
    private String batchId;

    @Column(name = "created_at", nullable = false, updatable = false)
    private Instant createdAt;

    protected LedgerEntry() {
        // for JPA
    }

    public LedgerEntry(
            UUID id,
            String accountId,
            EntryType entryType,
            long amountMinor,
            String currency,
            String idempotencyKey,
            String batchId,
            Instant createdAt) {
        this.id = id;
        this.accountId = accountId;
        this.entryType = entryType;
        this.amountMinor = amountMinor;
        this.currency = currency;
        this.idempotencyKey = idempotencyKey;
        this.batchId = batchId;
        this.createdAt = createdAt;
    }

    public UUID getId() {
        return id;
    }

    public String getAccountId() {
        return accountId;
    }

    public EntryType getEntryType() {
        return entryType;
    }

    public long getAmountMinor() {
        return amountMinor;
    }

    /** Minor units are the source of truth; this is presentation only. */
    public BigDecimal getAmount() {
        return BigDecimal.valueOf(amountMinor, 2);
    }

    public String getCurrency() {
        return currency;
    }

    public String getIdempotencyKey() {
        return idempotencyKey;
    }

    public String getBatchId() {
        return batchId;
    }

    public Instant getCreatedAt() {
        return createdAt;
    }

    /** Signed contribution of this entry to the account balance, in minor units. */
    public long signedAmountMinor() {
        return entryType == EntryType.DEBIT ? -amountMinor : amountMinor;
    }
}
