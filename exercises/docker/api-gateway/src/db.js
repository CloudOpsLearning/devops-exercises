import pg from 'pg';
import { config } from './config.js';
import { logger } from './logger.js';

const { Pool } = pg;

export class SchemaNotReadyError extends Error {
  constructor(message, details) {
    super(message);
    this.name = 'SchemaNotReadyError';
    this.details = details;
  }
}

export function createPool() {
  const pool = new Pool({
    host: config.postgres.host,
    port: config.postgres.port,
    database: config.postgres.database,
    user: config.postgres.user,
    password: config.postgres.password,
    max: config.postgres.poolSize,
    connectionTimeoutMillis: config.postgres.connectionTimeoutMillis,
    idleTimeoutMillis: 10_000,
    application_name: config.serviceName
  });

  pool.on('error', (err) => {
    logger.error('idle postgres client errored', { code: err.code, message: err.message });
  });

  return pool;
}

/**
 * Read the schema contract. There is deliberately no retry loop here:
 * this service assumes the schema owner has already finished its work.
 */
export async function assertSchemaReady(pool) {
  let rows;
  try {
    ({ rows } = await pool.query(
      'SELECT version, name, applied_at FROM platform_meta ORDER BY version DESC LIMIT 1'
    ));
  } catch (err) {
    if (err.code === '42P01') {
      throw new SchemaNotReadyError(
        'relation "platform_meta" does not exist - the schema owner has not finished',
        { pgCode: err.code, expected: config.expectedSchemaVersion }
      );
    }
    throw new SchemaNotReadyError(`cannot reach the database: ${err.message}`, {
      pgCode: err.code,
      host: config.postgres.host,
      port: config.postgres.port
    });
  }

  const current = rows[0]?.version ?? 0;
  if (current < config.expectedSchemaVersion) {
    throw new SchemaNotReadyError(
      `schema version ${current} is older than the required version ${config.expectedSchemaVersion}`,
      { current, expected: config.expectedSchemaVersion }
    );
  }

  logger.info('schema contract satisfied', { version: current, appliedAt: rows[0]?.applied_at });
  return current;
}

export async function insertAsset(pool, { assetId, sourceBytes, contentType }) {
  const { rows } = await pool.query(
    `INSERT INTO assets (asset_id, source_bytes, content_type, state)
     VALUES ($1, $2, $3, 'queued')
     ON CONFLICT (asset_id) DO UPDATE SET source_bytes = EXCLUDED.source_bytes, state = 'queued'
     RETURNING id, asset_id, state, created_at`,
    [assetId, sourceBytes, contentType]
  );
  return rows[0];
}

export async function recentAssets(pool, limit = 50) {
  const { rows } = await pool.query(
    `SELECT a.asset_id, a.state, a.source_bytes, a.created_at,
            (SELECT count(*) FROM processing_log p WHERE p.asset_id = a.asset_id) AS log_entries
     FROM assets a
     ORDER BY a.created_at DESC
     LIMIT $1`,
    [limit]
  );
  return rows;
}
