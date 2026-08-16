import { readFileSync } from 'node:fs';

const missing = [];

function raw(name) {
  const filePath = process.env[`${name}_FILE`];
  if (filePath) {
    try {
      return readFileSync(filePath, 'utf8').trim();
    } catch (err) {
      throw new Error(`${name}_FILE=${filePath} is set but unreadable (${err.code})`);
    }
  }
  const value = process.env[name];
  return value === undefined || value === '' ? undefined : value;
}

function required(name) {
  const value = raw(name);
  if (value === undefined) {
    missing.push(name);
    return undefined;
  }
  return value;
}

function optional(name, fallback) {
  const value = raw(name);
  return value === undefined ? fallback : value;
}

function int(name, fallback) {
  const value = fallback === undefined ? required(name) : optional(name, String(fallback));
  if (value === undefined) return undefined;
  const parsed = Number.parseInt(value, 10);
  if (!Number.isInteger(parsed)) throw new Error(`${name} must be an integer, received "${value}"`);
  return parsed;
}

export const config = Object.freeze({
  serviceName: optional('SERVICE_NAME', 'db-migrator'),
  postgres: Object.freeze({
    host: required('POSTGRES_HOST'),
    port: int('POSTGRES_PORT'),
    database: required('POSTGRES_DB'),
    user: required('POSTGRES_USER'),
    password: required('POSTGRES_PASSWORD'),
    // One shot. If the server is not accepting connections yet, that is not this
    // job's problem to solve - it is the orchestrator's job to start us at the right time.
    connectionTimeoutMillis: int('POSTGRES_CONNECT_TIMEOUT_MS', 3000)
  }),
  migrationsDir: required('MIGRATIONS_DIR'),
  // Schema work on the production-sized table set is not instant. Do not "fix" this.
  migrationDelayMs: int('MIGRATION_DELAY_MS', 4000),
  advisoryLockId: int('MIGRATION_LOCK_ID', 947103)
});

if (missing.length > 0) {
  process.stderr.write(
    `[config] refusing to run, missing required environment: ${missing.join(', ')}\n`
  );
  process.exit(64);
}
