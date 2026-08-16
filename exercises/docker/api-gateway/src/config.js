import { readFileSync } from 'node:fs';

/**
 * Secrets are read from `<NAME>_FILE` first, then from `<NAME>`.
 * Nothing in this repository is allowed to carry a default credential.
 */
const WEAK_SECRETS = new Set([
  'postgres',
  'password',
  'passwd',
  'pass',
  'changeme',
  'admin',
  'root',
  'secret',
  'redis',
  '123456'
]);

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

function int(name, { fallback } = {}) {
  const value = fallback === undefined ? required(name) : optional(name, String(fallback));
  if (value === undefined) return undefined;
  const parsed = Number.parseInt(value, 10);
  if (!Number.isInteger(parsed)) {
    throw new Error(`${name} must be an integer, received "${value}"`);
  }
  return parsed;
}

const nodeEnv = required('NODE_ENV');
const postgresPassword = required('POSTGRES_PASSWORD');
const redisPassword = optional('REDIS_PASSWORD', undefined);

export const config = Object.freeze({
  serviceName: optional('SERVICE_NAME', 'api-gateway'),
  nodeEnv,
  isProduction: nodeEnv === 'production',
  logLevel: optional('LOG_LEVEL', 'info'),
  port: int('PORT'),

  postgres: Object.freeze({
    host: required('POSTGRES_HOST'),
    port: int('POSTGRES_PORT'),
    database: required('POSTGRES_DB'),
    user: required('POSTGRES_USER'),
    password: postgresPassword,
    poolSize: int('POSTGRES_POOL_SIZE', { fallback: 8 }),
    connectionTimeoutMillis: int('POSTGRES_CONNECT_TIMEOUT_MS', { fallback: 3000 })
  }),

  redis: Object.freeze({
    host: required('REDIS_HOST'),
    port: int('REDIS_PORT'),
    password: redisPassword
  }),

  queueName: required('QUEUE_NAME'),
  scratchDir: required('SCRATCH_DIR'),
  processedSubdir: optional('PROCESSED_SUBDIR', 'processed'),

  appUid: int('APP_UID'),
  appGid: int('APP_GID'),

  expectedSchemaVersion: int('EXPECTED_SCHEMA_VERSION', { fallback: 3 }),
  shutdownDrainMs: int('SHUTDOWN_DRAIN_MS', { fallback: 750 }),
  shutdownHardTimeoutMs: int('SHUTDOWN_HARD_TIMEOUT_MS', { fallback: 5000 })
});

if (missing.length > 0) {
  process.stderr.write(
    `[config] refusing to boot, missing required environment: ${missing.join(', ')}\n`
  );
  process.exit(64);
}

if (config.isProduction) {
  const offenders = [];
  if (WEAK_SECRETS.has(postgresPassword.toLowerCase())) offenders.push('POSTGRES_PASSWORD');
  if (redisPassword && WEAK_SECRETS.has(redisPassword.toLowerCase())) offenders.push('REDIS_PASSWORD');
  if (offenders.length > 0) {
    process.stderr.write(
      `[config] refusing to boot in production with well-known credentials: ${offenders.join(', ')}\n`
    );
    process.exit(65);
  }
}
