import { readdir, readFile } from 'node:fs/promises';
import { join } from 'node:path';
import pg from 'pg';
import { config } from './config.js';

const { Client } = pg;

function log(level, msg, fields = {}) {
  const line = JSON.stringify({
    ts: new Date().toISOString(),
    level,
    service: config.serviceName,
    pid: process.pid,
    msg,
    ...fields
  });
  if (level === 'error' || level === 'fatal') process.stderr.write(`${line}\n`);
  else process.stdout.write(`${line}\n`);
}

const BOOTSTRAP_SQL = `
  CREATE TABLE IF NOT EXISTS platform_meta (
    version     integer PRIMARY KEY,
    name        text NOT NULL,
    checksum    text NOT NULL,
    applied_at  timestamptz NOT NULL DEFAULT now(),
    applied_by  text NOT NULL
  );
`;

function checksum(sql) {
  let hash = 0;
  for (let i = 0; i < sql.length; i += 1) {
    hash = (hash * 31 + sql.charCodeAt(i)) | 0;
  }
  return (hash >>> 0).toString(16).padStart(8, '0');
}

async function loadMigrations() {
  let files;
  try {
    files = (await readdir(config.migrationsDir)).filter((name) => name.endsWith('.sql')).sort();
  } catch (err) {
    log('fatal', 'migrations directory is unreadable', {
      migrationsDir: config.migrationsDir,
      code: err.code,
      hint: 'the migration SQL must be present in the runtime image, not only in the build context'
    });
    process.exit(66);
  }

  if (files.length === 0) {
    log('fatal', 'migrations directory contains no .sql files', { migrationsDir: config.migrationsDir });
    process.exit(66);
  }

  const migrations = [];
  for (const file of files) {
    const version = Number.parseInt(file.slice(0, file.indexOf('_')), 10);
    if (!Number.isInteger(version)) {
      log('fatal', 'migration filename must start with a numeric version', { file });
      process.exit(66);
    }
    const sql = await readFile(join(config.migrationsDir, file), 'utf8');
    migrations.push({ version, name: file, sql, checksum: checksum(sql) });
  }
  return migrations;
}

async function main() {
  if (typeof process.getuid === 'function' && process.getuid() === 0) {
    log('fatal', 'refusing to run schema changes as root', {
      hint: 'least privilege applies to one-shot jobs too'
    });
    process.exit(78);
  }

  const migrations = await loadMigrations();
  log('info', 'migration plan loaded', {
    count: migrations.length,
    versions: migrations.map((m) => m.version)
  });

  const client = new Client({
    host: config.postgres.host,
    port: config.postgres.port,
    database: config.postgres.database,
    user: config.postgres.user,
    password: config.postgres.password,
    connectionTimeoutMillis: config.postgres.connectionTimeoutMillis,
    application_name: config.serviceName
  });

  try {
    await client.connect();
  } catch (err) {
    log('fatal', 'could not connect to postgres on the first attempt and will not retry', {
      code: err.code,
      message: err.message,
      host: config.postgres.host,
      port: config.postgres.port
    });
    process.exit(70);
  }

  log('info', 'connected, preparing schema workspace', { delayMs: config.migrationDelayMs });
  // Table rewrites and index builds on the production data set take real time.
  await new Promise((resolve) => setTimeout(resolve, config.migrationDelayMs));

  let applied = 0;
  try {
    // Only one migrator may hold the schema at a time, no matter how many replicas start.
    await client.query('SELECT pg_advisory_lock($1)', [config.advisoryLockId]);
    await client.query(BOOTSTRAP_SQL);

    const { rows } = await client.query('SELECT version, checksum FROM platform_meta');
    const seen = new Map(rows.map((row) => [row.version, row.checksum]));

    for (const migration of migrations) {
      const known = seen.get(migration.version);
      if (known) {
        if (known !== migration.checksum) {
          log('fatal', 'migration content changed after it was applied', {
            version: migration.version,
            name: migration.name,
            applied: known,
            current: migration.checksum
          });
          process.exit(71);
        }
        log('info', 'migration already applied, skipping', { version: migration.version });
        continue;
      }

      await client.query('BEGIN');
      try {
        await client.query(migration.sql);
        await client.query(
          `INSERT INTO platform_meta (version, name, checksum, applied_by) VALUES ($1, $2, $3, $4)`,
          [migration.version, migration.name, migration.checksum, config.serviceName]
        );
        await client.query('COMMIT');
        applied += 1;
        log('info', 'migration applied', { version: migration.version, name: migration.name });
      } catch (err) {
        await client.query('ROLLBACK');
        log('fatal', 'migration failed and was rolled back', {
          version: migration.version,
          name: migration.name,
          code: err.code,
          message: err.message
        });
        process.exit(72);
      }
    }

    const { rows: finalRows } = await client.query(
      'SELECT max(version) AS version FROM platform_meta'
    );
    log('info', 'schema is up to date', { appliedNow: applied, version: finalRows[0].version });
  } finally {
    try {
      await client.query('SELECT pg_advisory_unlock($1)', [config.advisoryLockId]);
    } catch {
      // the connection is going away anyway; the lock is session scoped
    }
    await client.end();
  }

  process.exit(0);
}

main().catch((err) => {
  log('fatal', 'migrator crashed', { message: err.message, stack: err.stack });
  process.exit(1);
});
