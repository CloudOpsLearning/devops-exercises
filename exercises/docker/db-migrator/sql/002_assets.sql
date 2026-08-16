-- 002: the ingest table the gateway writes to.

CREATE TABLE IF NOT EXISTS assets (
  id            bigserial PRIMARY KEY,
  asset_id      text NOT NULL UNIQUE,
  source_bytes  bigint NOT NULL DEFAULT 0,
  content_type  text NOT NULL DEFAULT 'application/octet-stream',
  state         text NOT NULL DEFAULT 'queued',
  created_at    timestamptz NOT NULL DEFAULT now(),
  processed_at  timestamptz,
  CONSTRAINT assets_state_valid CHECK (state IN ('queued', 'processing', 'processed', 'failed'))
);

CREATE INDEX IF NOT EXISTS assets_created_at_idx ON assets (created_at DESC);
CREATE INDEX IF NOT EXISTS assets_state_idx ON assets (state);
