import { getHeapStatistics } from 'node:v8';
import { config } from './config.js';
import { logger } from './logger.js';

const ROWS_PER_CHUNK = 2048;
const FILLER = 'x'.repeat(96);

function buildChunk(index) {
  const rows = new Array(ROWS_PER_CHUNK);
  for (let i = 0; i < ROWS_PER_CHUNK; i += 1) {
    rows[i] = {
      tile: `${index}:${i}`,
      checksum: `${FILLER}${index}${i}`,
      histogram: [i % 255, (i * 7) % 255, (i * 13) % 255],
      exif: { make: 'helios', model: 'orbital-8', lens: `${FILLER.slice(0, 32)}${i}` }
    };
  }
  return rows;
}

/**
 * Real decoders materialise the whole tile pyramid before they can emit metadata.
 * This reproduces that shape: live JavaScript objects in the V8 old space, not
 * off-heap buffers, held for the duration of the job.
 *
 * The heap it needs is SPIKE_MB. What V8 is *allowed* to use is a separate number,
 * and what the container is allowed to use is a third. All three have to agree.
 */
export async function runProcessingSpike(megabytes = config.spikeMegabytes) {
  const target = megabytes * 1024 * 1024;
  const before = process.memoryUsage().heapUsed;
  const limit = getHeapStatistics().heap_size_limit;
  const startedAt = Date.now();

  logger.info('processing spike starting', {
    requestedMb: megabytes,
    heapUsedMb: Math.round(before / 1048576),
    v8HeapLimitMb: Math.round(limit / 1048576)
  });

  const pyramid = [];
  const maxChunks = megabytes * 16;
  while (process.memoryUsage().heapUsed - before < target && pyramid.length < maxChunks) {
    pyramid.push(buildChunk(pyramid.length));
    if (pyramid.length % 64 === 0) {
      // Yield so the heartbeat and signal handlers still get a turn.
      await new Promise((resolve) => setImmediate(resolve));
    }
  }

  const peak = process.memoryUsage();
  await new Promise((resolve) => setTimeout(resolve, config.spikeHoldMs));

  const summary = {
    requestedMb: megabytes,
    chunks: pyramid.length,
    tiles: pyramid.length * ROWS_PER_CHUNK,
    peakHeapUsedMb: Math.round(peak.heapUsed / 1048576),
    peakRssMb: Math.round(peak.rss / 1048576),
    v8HeapLimitMb: Math.round(limit / 1048576),
    durationMs: Date.now() - startedAt
  };

  pyramid.length = 0;
  logger.info('processing spike released', summary);
  return summary;
}

export function describeMemory() {
  const usage = process.memoryUsage();
  const stats = getHeapStatistics();
  return {
    rssMb: Math.round(usage.rss / 1048576),
    heapUsedMb: Math.round(usage.heapUsed / 1048576),
    heapTotalMb: Math.round(usage.heapTotal / 1048576),
    externalMb: Math.round(usage.external / 1048576),
    v8HeapLimitMb: Math.round(stats.heap_size_limit / 1048576)
  };
}
