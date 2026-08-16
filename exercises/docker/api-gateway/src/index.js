import { randomUUID } from 'node:crypto';
import { availableParallelism } from 'node:os';
import { getHeapStatistics } from 'node:v8';
import express from 'express';
import { config } from './config.js';
import { logger } from './logger.js';
import { assertRuntimeIdentity } from './identity.js';
import { prepareScratch, listProcessed, processedDir } from './scratch.js';
import { assertSchemaReady, createPool, insertAsset, recentAssets } from './db.js';
import { createQueue, createRedis } from './queue.js';
import { registerLifecycle } from './lifecycle.js';

const bootedAt = Date.now();

function buildApp({ pool, queue, redis }) {
  const app = express();
  app.disable('x-powered-by');
  app.use(express.json({ limit: '256kb' }));

  // Liveness: is the event loop still ours? Never touches a dependency.
  app.get('/healthz', (_req, res) => {
    res.status(200).json({
      status: 'alive',
      service: config.serviceName,
      pid: process.pid,
      uptimeMs: Date.now() - bootedAt
    });
  });

  // Readiness: can we actually serve a request end to end?
  app.get('/readyz', async (_req, res) => {
    const checks = {};
    let ok = true;

    try {
      const { rows } = await pool.query('SELECT version FROM platform_meta ORDER BY version DESC LIMIT 1');
      checks.postgres = { ok: true, schemaVersion: rows[0]?.version ?? 0 };
      if ((rows[0]?.version ?? 0) < config.expectedSchemaVersion) {
        checks.postgres.ok = false;
        ok = false;
      }
    } catch (err) {
      checks.postgres = { ok: false, code: err.code, message: err.message };
      ok = false;
    }

    try {
      checks.redis = { ok: (await redis.ping()) === 'PONG' };
      if (!checks.redis.ok) ok = false;
    } catch (err) {
      checks.redis = { ok: false, message: err.message };
      ok = false;
    }

    const processed = await listProcessed(1);
    checks.scratch = { ok: processed.readable, dir: processedDir, error: processed.error };
    if (!processed.readable) ok = false;

    res.status(ok ? 200 : 503).json({ status: ok ? 'ready' : 'degraded', checks });
  });

  // Ingest one asset: durable row first, then the queue entry.
  app.post('/ingest', async (req, res) => {
    const assetId = req.body?.assetId ?? `asset-${randomUUID()}`;
    const sourceBytes = Number.parseInt(req.body?.sourceBytes ?? '2048', 10);
    const contentType = req.body?.contentType ?? 'image/jpeg';

    try {
      const row = await insertAsset(pool, { assetId, sourceBytes, contentType });
      const job = await queue.add('metadata', { assetId, sourceBytes, contentType });
      res.status(202).json({ accepted: true, assetId: row.asset_id, jobId: job.id });
    } catch (err) {
      logger.error('ingest failed', { assetId, code: err.code, message: err.message });
      res.status(503).json({ accepted: false, error: err.message });
    }
  });

  // Deliberate memory pressure on the worker. Used by the acceptance suite.
  app.post('/ingest/spike', async (req, res) => {
    const megabytes = Number.parseInt(req.body?.megabytes ?? '0', 10) || undefined;
    const assetId = req.body?.assetId ?? `spike-${randomUUID()}`;
    try {
      await insertAsset(pool, { assetId, sourceBytes: (megabytes ?? 0) * 1024 * 1024, contentType: 'image/tiff' });
      const job = await queue.add('spike', { assetId, megabytes });
      res.status(202).json({ accepted: true, assetId, jobId: job.id, megabytes: megabytes ?? 'service default' });
    } catch (err) {
      logger.error('spike enqueue failed', { assetId, message: err.message });
      res.status(503).json({ accepted: false, error: err.message });
    }
  });

  app.get('/assets', async (_req, res) => {
    try {
      const [rows, processed] = await Promise.all([recentAssets(pool), listProcessed()]);
      res.json({ database: rows, scratch: processed });
    } catch (err) {
      res.status(503).json({ error: err.message });
    }
  });

  app.get('/queue/stats', async (_req, res) => {
    try {
      res.json(await queue.getJobCounts('waiting', 'active', 'completed', 'failed', 'delayed'));
    } catch (err) {
      res.status(503).json({ error: err.message });
    }
  });

  // Everything an operator needs to explain "why did this container behave that way".
  app.get('/debug/runtime', (_req, res) => {
    res.json({
      pid: process.pid,
      ppid: process.ppid,
      uid: process.getuid(),
      gid: process.getgid(),
      groups: process.getgroups(),
      nodeEnv: config.nodeEnv,
      execArgv: process.execArgv,
      argv: process.argv,
      heapSizeLimitBytes: getHeapStatistics().heap_size_limit,
      memoryUsage: process.memoryUsage(),
      availableParallelism: availableParallelism()
    });
  });

  return app;
}

async function bootstrap() {
  assertRuntimeIdentity();
  await prepareScratch();

  const pool = createPool();
  const schemaVersion = await assertSchemaReady(pool);

  const redis = createRedis();
  const queue = createQueue(redis);
  const app = buildApp({ pool, queue, redis });

  const server = app.listen(config.port, '0.0.0.0', () => {
    logger.info('gateway listening', { port: config.port, schemaVersion, nodeEnv: config.nodeEnv });
  });
  server.keepAliveTimeout = 5000;
  server.headersTimeout = 6000;

  registerLifecycle({
    onDrain: async () => {
      await new Promise((resolve) => server.close(resolve));
    },
    closers: [
      { name: 'bullmq-queue', close: () => queue.close() },
      { name: 'redis', close: () => redis.quit() },
      { name: 'postgres-pool', close: () => pool.end() }
    ]
  });
}

// Kick off the boot sequence. The platform supervisor restarts us if it throws.
bootstrap();
