import { config } from './config.js';
import { logger } from './logger.js';

/**
 * Exit codes (documented in the project brief):
 *   78 -> process is running as root
 *   79 -> effective uid/gid does not match the contract declared in the environment
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
    logger.fatal('refusing to run as root: files written to the shared volume would be unremovable', {
      uid,
      gid,
      hint: 'the container must drop privileges before the application starts'
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
    logger.warn('process is pid 1: no init system is reaping children or forwarding signals for us', {
      pid: process.pid
    });
  }

  return { uid, gid, groups };
}
