import { get } from 'node:http';
import { config } from './config.js';

/**
 * Container-side health probe. Exits 0 when the gateway is ready to serve,
 * 1 otherwise. Intentionally dependency free so it can run inside a slim image.
 */
const path = process.argv[2] ?? '/readyz';
const timeoutMs = Number.parseInt(process.env.HEALTHCHECK_TIMEOUT_MS ?? '2000', 10);

const req = get({ host: '127.0.0.1', port: config.port, path, timeout: timeoutMs }, (res) => {
  let body = '';
  res.setEncoding('utf8');
  res.on('data', (chunk) => {
    body += chunk;
  });
  res.on('end', () => {
    process.stdout.write(`${res.statusCode} ${body.slice(0, 500)}\n`);
    process.exit(res.statusCode === 200 ? 0 : 1);
  });
});

req.on('timeout', () => {
  req.destroy();
  process.stderr.write(`healthcheck timed out after ${timeoutMs}ms\n`);
  process.exit(1);
});

req.on('error', (err) => {
  process.stderr.write(`healthcheck failed: ${err.message}\n`);
  process.exit(1);
});
