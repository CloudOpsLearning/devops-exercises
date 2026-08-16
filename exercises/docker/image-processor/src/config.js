import { readFileSync } from 'node:fs';

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
  serviceName: optional('SERVICE_NAME', 'image-processor'),
  nodeEnv,
  isProduction: nodeEnv === 'production',
  logLevel: optional('LOG_LEVEL', 'info'),

  postgres: Object.freeze({
    host: required('POSTGRES_HOST'),
    port: int('POSTGRES_PORT'),
    database: required('POSTGRES_DB'),
    user: required('POSTGRES_USER'),
    password: postgresPassword,
    poolSize: int('POSTGRES_POOL_SIZE', { fallback: 4 }),
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
  shutdownHardTimeoutMs: int('SHUTDOWN_HARD_TIMEOUT_MS', { fallback: 5000 }),

  workerConcurrency: int('WORKER_CONCURRENCY', { fallback: 4 }),
  spikeMegabytes: int('SPIKE_MB', { fallback: 320 }),
  spikeHoldMs: int('SPIKE_HOLD_MS', { fallback: 1200 }),
  heartbeatIntervalMs: int('HEARTBEAT_INTERVAL_MS', { fallback: 5000 }),
  heartbeatStaleMs: int('HEARTBEAT_STALE_MS', { fallback: 20000 }),
  zombieThreshold: int('ZOMBIE_THRESHOLD', { fallback: 25 }),

  // Every job shells out to the legacy exif sidecar. It backgrounds its own work.
  sidecarEnabled: optional('SIDECAR_ENABLED', 'true') === 'true',
  sidecarLingerSeconds: int('SIDECAR_LINGER_SECONDS', { fallback: 12 })
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
