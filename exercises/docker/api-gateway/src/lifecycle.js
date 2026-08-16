import { config } from './config.js';
import { logger } from './logger.js';
import { writeShutdownMarker } from './scratch.js';

const HANDLED_SIGNALS = ['SIGTERM', 'SIGINT'];

/**
 * Graceful shutdown contract:
 *   1. stop accepting new work
 *   2. drain in-flight work for at most SHUTDOWN_DRAIN_MS
 *   3. close database + redis handles so no half-open sessions leak
 *   4. drop a marker on the shared volume proving the signal was received
 *
 * The whole sequence is designed to finish well inside two seconds. If the
 * marker is missing after a restart, this code never ran - which means the
 * signal never reached this process.
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
