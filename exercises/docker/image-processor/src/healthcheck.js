import { readFile } from 'node:fs/promises';
import IORedis from 'ioredis';
import { config } from './config.js';
import { heartbeatFile } from './scratch.js';
import { countZombies } from './sidecar.js';

/**
 * The worker exposes no HTTP surface, so its health is derived from three facts:
 *   - the heartbeat file on the shared volume is fresh
 *   - redis answers PING
 *   - the pid namespace is not filling up with unreaped children
 *
 * Exits 0 when healthy, 1 otherwise, and prints the reason.
 */
const failures = [];

try {
  const raw = await readFile(heartbeatFile, 'utf8');
  const beat = JSON.parse(raw);
  const ageMs = Date.now() - Date.parse(beat.at);
  if (!Number.isFinite(ageMs) || ageMs > config.heartbeatStaleMs) {
    failures.push(`heartbeat is stale (${ageMs}ms > ${config.heartbeatStaleMs}ms)`);
  }
} catch (err) {
  failures.push(`heartbeat unreadable: ${err.code ?? err.message}`);
}

const redis = new IORedis({
  host: config.redis.host,
  port: config.redis.port,
  password: config.redis.password,
  maxRetriesPerRequest: 1,
  connectTimeout: 1500,
  lazyConnect: true
});

try {
  await redis.connect();
  const pong = await redis.ping();
  if (pong !== 'PONG') failures.push(`unexpected redis reply: ${pong}`);
} catch (err) {
  failures.push(`redis unreachable: ${err.message}`);
} finally {
  redis.disconnect();
}

const { supported, zombies, processes } = await countZombies();
if (supported && zombies > config.zombieThreshold) {
  failures.push(`${zombies} zombie processes (threshold ${config.zombieThreshold}, ${processes} pids)`);
}

if (failures.length > 0) {
  process.stderr.write(`unhealthy: ${failures.join('; ')}\n`);
  process.exit(1);
}

process.stdout.write(`healthy: zombies=${zombies} pids=${processes}\n`);
process.exit(0);
