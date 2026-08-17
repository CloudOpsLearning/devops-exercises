-- V3: what month-end reconciliation actually queries.
-- This is the version the running application asserts on: an image built for schema 3
-- that is pointed at a version 2 database will report itself out of service rather
-- than serve finance a partial report.

CREATE INDEX ledger_entries_batch_idx ON ledger_entries (batch_id) WHERE batch_id IS NOT NULL;
CREATE INDEX ledger_entries_created_at_idx ON ledger_entries (created_at DESC);

COMMENT ON TABLE ledger_entries IS 'Append-only driver settlement ledger. Schema contract version 3.';
