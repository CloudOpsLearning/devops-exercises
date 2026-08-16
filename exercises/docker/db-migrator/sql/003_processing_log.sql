-- 003: append-only record of what the worker actually did.
-- This is the version the application code asserts on (EXPECTED_SCHEMA_VERSION).

CREATE TABLE IF NOT EXISTS processing_log (
  id               bigserial PRIMARY KEY,
  asset_id         text NOT NULL,
  kind             text NOT NULL,
  duration_ms      integer NOT NULL,
  heap_used_bytes  bigint NOT NULL DEFAULT 0,
  artifact_path    text,
  worker_pid       integer,
  logged_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT processing_log_kind_valid CHECK (kind IN ('metadata', 'spike'))
);

CREATE INDEX IF NOT EXISTS processing_log_asset_idx ON processing_log (asset_id);
CREATE INDEX IF NOT EXISTS processing_log_logged_at_idx ON processing_log (logged_at DESC);
