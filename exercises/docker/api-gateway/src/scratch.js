import { constants } from 'node:fs';
import { access, chmod, mkdir, readdir, readFile, rm, stat, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { config } from './config.js';
import { logger } from './logger.js';

export const shutdownDir = join(config.scratchDir, 'shutdown');
export const processedDir = join(config.scratchDir, config.processedSubdir);

async function ensureDir(path, mode) {
  await mkdir(path, { recursive: true, mode });
  try {
    await chmod(path, mode);
  } catch (err) {
    // Another service may own the directory. Group permissions must already allow us in.
    if (err.code !== 'EPERM') throw err;
  }
}

/**
 * The shared volume is the only place the gateway and the worker meet.
 * If we cannot write to it there is no point in serving traffic.
 * Exit code 77 -> shared scratch is not writable by this uid/gid.
 */
export async function prepareScratch() {
  try {
    await ensureDir(config.scratchDir, 0o2770);
    await ensureDir(shutdownDir, 0o2770);
    const probe = join(config.scratchDir, `.probe-${config.serviceName}`);
    await writeFile(probe, `${process.getuid()}:${process.getgid()}\n`, { mode: 0o640 });
    await rm(probe, { force: true });
  } catch (err) {
    logger.fatal('shared scratch is not writable', {
      scratchDir: config.scratchDir,
      code: err.code,
      uid: process.getuid(),
      gid: process.getgid(),
      hint: 'the volume must be owned by, or group-writable for, the declared APP_UID/APP_GID'
    });
    process.exit(77);
  }

  logger.info('shared scratch ready', { scratchDir: config.scratchDir });
}

export async function listProcessed(limit = 50) {
  try {
    await access(processedDir, constants.R_OK | constants.X_OK);
  } catch (err) {
    if (err.code === 'ENOENT') return { readable: true, entries: [] };
    return { readable: false, error: err.code, entries: [] };
  }

  const names = (await readdir(processedDir)).filter((name) => name.endsWith('.json')).sort().slice(-limit);
  const entries = [];
  for (const name of names) {
    const path = join(processedDir, name);
    try {
      const [info, body] = await Promise.all([stat(path), readFile(path, 'utf8')]);
      entries.push({
        file: name,
        bytes: info.size,
        mode: (info.mode & 0o7777).toString(8),
        uid: info.uid,
        gid: info.gid,
        payload: JSON.parse(body)
      });
    } catch (err) {
      entries.push({ file: name, error: err.code ?? 'UNREADABLE' });
    }
  }
  return { readable: true, entries };
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
