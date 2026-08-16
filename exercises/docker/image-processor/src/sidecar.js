import { spawn } from 'node:child_process';
import { readdir, readFile } from 'node:fs/promises';
import { config } from './config.js';
import { logger } from './logger.js';

/**
 * The legacy exif sidecar is a shell wrapper that backgrounds its own worker and
 * returns immediately, so the background job is re-parented away from us the moment
 * the wrapper exits. We never wait for it - it writes its own telemetry elsewhere.
 *
 * Whoever ends up as the parent of those orphans is responsible for reaping them.
 */
export function spawnSidecarProbe(assetId) {
  if (!config.sidecarEnabled) return null;

  const child = spawn('/bin/sh', ['-c', `sleep ${config.sidecarLingerSeconds} & exit 0`], {
    stdio: 'ignore'
  });

  child.on('error', (err) => {
    logger.warn('sidecar probe could not start', { assetId, message: err.message });
  });

  return child.pid;
}

/**
 * Counts processes in state Z inside this PID namespace. A healthy container has
 * zero; a container whose PID 1 does not reap will climb until it hits the pid limit.
 */
export async function countZombies() {
  let entries;
  try {
    entries = await readdir('/proc');
  } catch {
    return { supported: false, zombies: 0, processes: 0 };
  }

  let zombies = 0;
  let processes = 0;
  for (const entry of entries) {
    if (!/^\d+$/.test(entry)) continue;
    processes += 1;
    try {
      const stat = await readFile(`/proc/${entry}/stat`, 'utf8');
      const state = stat.slice(stat.lastIndexOf(')') + 2, stat.lastIndexOf(')') + 3);
      if (state === 'Z') zombies += 1;
    } catch {
      // process exited between readdir and read; nothing to count
    }
  }

  return { supported: true, zombies, processes };
}
