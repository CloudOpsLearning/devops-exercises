-- V1: the ledger itself. Append only: no UPDATE, no DELETE, ever.

CREATE TABLE ledger_entries (
    id              uuid PRIMARY KEY,
    account_id      varchar(64) NOT NULL,
    entry_type      varchar(16) NOT NULL,
    amount_minor    bigint NOT NULL,
    currency        varchar(3) NOT NULL,
    idempotency_key varchar(128),
    batch_id        varchar(64),
    created_at      timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ledger_entries_type_valid CHECK (entry_type IN ('CREDIT', 'DEBIT')),
    CONSTRAINT ledger_entries_amount_positive CHECK (amount_minor > 0)
);

CREATE INDEX ledger_entries_account_created_idx ON ledger_entries (account_id, created_at DESC);
