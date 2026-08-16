import { chmod, mkdir, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { config } from './config.js';
import { logger } from './logger.js';

export const processedDir = join(config.scratchDir, config.processedSubdir);
export const shutdownDir = join(config.scratchDir, 'shutdown');
export const heartbeatFile = join(config.scratchDir, `.heartbeat-${config.serviceName}`);

async function ensureDir(path, mode) {
  await mkdir(path, { recursive: true, mode });
  try {
    await chmod(path, mode);
  } catch (err) {
    if (err.code !== 'EPERM') throw err;
  }
}

/**
 * Artifact permissions are a hard requirement from the security review:
 *   directories 2750 (setgid so the shared group survives)
 *   files       0640 (group readable, never world readable)
 *
 * Exit code 77 -> shared scratch is not writable by this uid/gid.
 */
export async function prepareScratch() {
  try {
    await ensureDir(config.scratchDir, 0o2770);
    await ensureDir(processedDir, 0o2750);
    await ensureDir(shutdownDir, 0o2770);
    const probe = join(processedDir, `.probe-${process.pid}`);
    await writeFile(probe, 'ok\n', { mode: 0o640 });
    await rm(probe, { force: true });
  } catch (err) {
    logger.fatal('shared scratch is not writable', {
      scratchDir: config.scratchDir,
      processedDir,
      code: err.code,
      uid: process.getuid(),
      gid: process.getgid(),
      hint: 'the volume must be owned by, or group-writable for, the declared APP_UID/APP_GID'
    });
    process.exit(77);
  }

  logger.info('shared scratch ready', { processedDir });
}

export async function writeArtifact(assetId, payload) {
  const path = join(processedDir, `${assetId}.json`);
  await writeFile(path, `${JSON.stringify(payload, null, 2)}\n`, { mode: 0o640 });
  await chmod(path, 0o640);
  return path;
}

export async function touchHeartbeat(extra = {}) {
  await writeFile(
    heartbeatFile,
    `${JSON.stringify({ at: new Date().toISOString(), pid: process.pid, ...extra })}\n`,
    { mode: 0o640 }
  );
}

export async function writeShutdownMarker(signal, durationMs) {
  const path = join(shutdownDir, `${config.serviceName}.json`);
  const payload = {
    service: config.serviceName,
    signal,
    pid: process.pid,
    graceful: true,
    durationMs,
    at: new Date().toISOString()
  };
  await writeFile(path, `${JSON.stringify(payload, null, 2)}\n`, { mode: 0o640 });
  return path;
}
