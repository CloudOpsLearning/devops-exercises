import { Worker } from 'bullmq';
import IORedis from 'ioredis';
import { config } from './config.js';
import { logger } from './logger.js';
import { assertRuntimeIdentity } from './identity.js';
import { prepareScratch, touchHeartbeat, writeArtifact } from './scratch.js';
import { assertSchemaReady, createPool, recordProcessing } from './db.js';
import { describeMemory, runProcessingSpike } from './heavy.js';
import { countZombies, spawnSidecarProbe } from './sidecar.js';
import { registerLifecycle } from './lifecycle.js';

function createRedis() {
  const connection = new IORedis({
    host: config.redis.host,
    port: config.redis.port,
    password: config.redis.password,
    // BullMQ workers require blocking commands to never time out.
    maxRetriesPerRequest: null,
    enableReadyCheck: true,
    retryStrategy: (attempt) => (attempt > 20 ? null : Math.min(attempt * 200, 2000))
  });

  connection.on('error', (err) => {
    logger.error('redis connection error', { code: err.code, message: err.message });
  });

  return connection;
}

async function handleMetadata(pool, job) {
  const startedAt = Date.now();
  const { assetId, sourceBytes = 0, contentType = 'application/octet-stream' } = job.data;

  spawnSidecarProbe(assetId);

  const artifact = {
    assetId,
    contentType,
    sourceBytes,
    derived: {
      width: 1024 + (sourceBytes % 512),
      height: 768 + (sourceBytes % 256),
      colorSpace: 'srgb',
      checksum: Buffer.from(`${assetId}:${sourceBytes}`).toString('base64')
    },
    worker: { pid: process.pid, uid: process.getuid(), gid: process.getgid() },
    memory: describeMemory(),
    at: new Date().toISOString()
  };

  const artifactPath = await writeArtifact(assetId, artifact);
  const durationMs = Date.now() - startedAt;
  await recordProcessing(pool, {
    assetId,
    kind: 'metadata',
    durationMs,
    heapUsedBytes: process.memoryUsage().heapUsed,
    artifactPath
  });

  return { assetId, artifactPath, durationMs };
}

async function handleSpike(pool, job) {
  const startedAt = Date.now();
  const assetId = job.data.assetId ?? `spike-${job.id}`;
  spawnSidecarProbe(assetId);

  const summary = await runProcessingSpike(job.data.megabytes);
  const artifactPath = await writeArtifact(assetId, {
    assetId,
    kind: 'spike',
    summary,
    worker: { pid: process.pid, uid: process.getuid(), gid: process.getgid() },
    at: new Date().toISOString()
  });

  const durationMs = Date.now() - startedAt;
  await recordProcessing(pool, {
    assetId,
    kind: 'spike',
    durationMs,
    heapUsedBytes: process.memoryUsage().heapUsed,
    artifactPath
  });

  return { assetId, artifactPath, durationMs, summary };
}

async function bootstrap() {
  assertRuntimeIdentity();
  await prepareScratch();

  const pool = createPool();
  const schemaVersion = await assertSchemaReady(pool);

  const connection = createRedis();
  const worker = new Worker(
    config.queueName,
    async (job) => (job.name === 'spike' ? handleSpike(pool, job) : handleMetadata(pool, job)),
    { connection, concurrency: config.workerConcurrency }
  );

  worker.on('completed', (job, result) => {
    logger.info('job completed', { jobId: job.id, name: job.name, durationMs: result?.durationMs });
  });

  worker.on('failed', (job, err) => {
    logger.error('job failed', { jobId: job?.id, name: job?.name, message: err.message });
  });

  const heartbeat = setInterval(() => {
    void (async () => {
      const { zombies, processes } = await countZombies();
      if (zombies > config.zombieThreshold) {
        logger.warn('orphaned children are accumulating in this pid namespace', {
          zombies,
          processes,
          threshold: config.zombieThreshold
        });
      }
      await touchHeartbeat({ zombies, processes, memory: describeMemory() });
    })().catch((err) => logger.error('heartbeat failed', { message: err.message }));
  }, config.heartbeatIntervalMs);

  await touchHeartbeat({ boot: true });
  logger.info('worker online', {
    queue: config.queueName,
    concurrency: config.workerConcurrency,
    schemaVersion,
    spikeMb: config.spikeMegabytes,
    memory: describeMemory()
  });

  registerLifecycle({
    onDrain: async () => {
      clearInterval(heartbeat);
      await worker.close();
    },
    closers: [
      { name: 'redis', close: () => connection.quit() },
      { name: 'postgres-pool', close: () => pool.end() }
    ]
  });
}

// Kick off the boot sequence. The platform supervisor restarts us if it throws.
bootstrap();
