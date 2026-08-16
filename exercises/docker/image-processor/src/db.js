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
 * The worker owns no schema. It asserts the contract and dies if it is not met -
 * a worker that writes into a half-created schema is worse than a worker that is down.
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

export async function recordProcessing(pool, { assetId, kind, durationMs, heapUsedBytes, artifactPath }) {
  await pool.query(
    `INSERT INTO processing_log (asset_id, kind, duration_ms, heap_used_bytes, artifact_path, worker_pid)
     VALUES ($1, $2, $3, $4, $5, $6)`,
    [assetId, kind, durationMs, heapUsedBytes, artifactPath, process.pid]
  );
  await pool.query(`UPDATE assets SET state = 'processed', processed_at = now() WHERE asset_id = $1`, [
    assetId
  ]);
}
