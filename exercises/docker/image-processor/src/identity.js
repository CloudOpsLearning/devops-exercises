import { config } from './config.js';
import { logger } from './logger.js';

/**
 * The worker is the only writer on the shared volume, so it is the service that
 * decides who owns the resulting files. It refuses to run under an identity that
 * would produce artifacts the host operator cannot delete.
 *
 * Exit codes:
 *   78 -> running as root
 *   79 -> uid/gid does not match the declared contract
 */
export function assertRuntimeIdentity() {
  if (typeof process.getuid !== 'function') {
    logger.fatal('this service only runs on POSIX hosts');
    process.exit(78);
  }

  const uid = process.getuid();
  const gid = process.getgid();
  const groups = process.getgroups();

  if (uid === 0) {
    logger.fatal('refusing to run as root: processed artifacts would be root-owned on the host', {
      uid,
      gid,
      hint: 'drop privileges in the image, not at runtime with chown -R'
    });
    process.exit(78);
  }

  if (uid !== config.appUid) {
    logger.fatal('uid contract violated', { runtimeUid: uid, declaredUid: config.appUid });
    process.exit(79);
  }

  if (gid !== config.appGid && !groups.includes(config.appGid)) {
    logger.fatal('gid contract violated: the shared scratch group is not attached to this process', {
      runtimeGid: gid,
      runtimeGroups: groups,
      declaredGid: config.appGid
    });
    process.exit(79);
  }

  logger.info('runtime identity accepted', { uid, gid, groups, pid: process.pid, ppid: process.ppid });

  if (process.pid === 1) {
    logger.warn('process is pid 1: this process is now responsible for reaping orphaned children', {
      pid: process.pid,
      sidecarEnabled: config.sidecarEnabled
    });
  }

  return { uid, gid, groups };
}
