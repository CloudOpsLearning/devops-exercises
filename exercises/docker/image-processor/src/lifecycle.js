import { config } from './config.js';
import { logger } from './logger.js';
import { writeShutdownMarker } from './scratch.js';

const HANDLED_SIGNALS = ['SIGTERM', 'SIGINT'];

/**
 * Graceful shutdown contract:
 *   1. stop pulling new jobs off the queue
 *   2. let the in-flight job finish (bounded by SHUTDOWN_DRAIN_MS)
 *   3. close the postgres pool and the redis connection
 *   4. drop a marker on the shared volume proving the signal was received
 *
 * If the marker is missing after a restart, this code never ran.
 */
export function registerLifecycle({ closers = [], onDrain } = {}) {
  let shuttingDown = false;

  const shutdown = async (signal) => {
    if (shuttingDown) {
      logger.warn('second signal during shutdown, ignoring', { signal });
      return;
    }
    shuttingDown = true;
    const startedAt = Date.now();
    logger.info('signal received, draining', { signal, drainMs: config.shutdownDrainMs });

    const hardTimer = setTimeout(() => {
      logger.fatal('graceful shutdown exceeded its hard timeout, aborting', {
        signal,
        hardTimeoutMs: config.shutdownHardTimeoutMs
      });
      process.exit(1);
    }, config.shutdownHardTimeoutMs);
    hardTimer.unref();

    try {
      if (onDrain) await onDrain(signal);
      await new Promise((resolve) => setTimeout(resolve, config.shutdownDrainMs));

      for (const closer of closers) {
        try {
          await closer.close();
          logger.info('resource closed', { resource: closer.name });
        } catch (err) {
          logger.error('resource failed to close cleanly', {
            resource: closer.name,
            message: err.message
          });
        }
      }

      const durationMs = Date.now() - startedAt;
      const marker = await writeShutdownMarker(signal, durationMs);
      logger.info('graceful shutdown complete', { signal, durationMs, marker });
      clearTimeout(hardTimer);
      process.exit(0);
    } catch (err) {
      logger.fatal('graceful shutdown failed', { signal, message: err.message });
      clearTimeout(hardTimer);
      process.exit(1);
    }
  };

  for (const signal of HANDLED_SIGNALS) {
    process.on(signal, () => {
      void shutdown(signal);
    });
  }

  logger.info('lifecycle handlers registered', { signals: HANDLED_SIGNALS, pid: process.pid });
}
