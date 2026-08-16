-- 001: ownership marker for the Helios schema.
-- platform_meta itself is bootstrapped by the migrator before this file runs;
-- this migration only records intent and adds the auditing columns.

COMMENT ON TABLE platform_meta IS 'Schema contract between db-migrator and every consumer service.';

CREATE TABLE IF NOT EXISTS schema_owner (
  id          smallint PRIMARY KEY DEFAULT 1,
  owner       text NOT NULL,
  claimed_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT schema_owner_singleton CHECK (id = 1)
);

INSERT INTO schema_owner (id, owner)
VALUES (1, 'db-migrator')
ON CONFLICT (id) DO UPDATE SET owner = EXCLUDED.owner, claimed_at = now();
