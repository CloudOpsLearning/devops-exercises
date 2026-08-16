import { config } from './config.js';

const LEVELS = { debug: 10, info: 20, warn: 30, error: 40, fatal: 50 };
const threshold = LEVELS[config.logLevel] ?? LEVELS.info;

function emit(level, message, fields) {
  if (LEVELS[level] < threshold) return;
  const line = JSON.stringify({
    ts: new Date().toISOString(),
    level,
    service: config.serviceName,
    pid: process.pid,
    msg: message,
    ...fields
  });
  if (LEVELS[level] >= LEVELS.error) process.stderr.write(`${line}\n`);
  else process.stdout.write(`${line}\n`);
}

export const logger = {
  debug: (msg, fields) => emit('debug', msg, fields),
  info: (msg, fields) => emit('info', msg, fields),
  warn: (msg, fields) => emit('warn', msg, fields),
  error: (msg, fields) => emit('error', msg, fields),
  fatal: (msg, fields) => emit('fatal', msg, fields)
};
