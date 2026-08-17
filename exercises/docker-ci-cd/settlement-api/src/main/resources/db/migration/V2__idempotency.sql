-- V2: retried payout webhooks must never move money twice.
-- The unique index is the only thing standing between a duplicate callback and a
-- duplicate credit, so it lives in the database rather than in application logic.

CREATE UNIQUE INDEX ledger_entries_idempotency_key_uidx
    ON ledger_entries (idempotency_key)
    WHERE idempotency_key IS NOT NULL;
