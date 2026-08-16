import { Queue } from 'bullmq';
import IORedis from 'ioredis';
import { config } from './config.js';
import { logger } from './logger.js';

export function createRedis() {
  const connection = new IORedis({
    host: config.redis.host,
    port: config.redis.port,
    password: config.redis.password,
    maxRetriesPerRequest: null,
    enableReadyCheck: true,
    lazyConnect: false,
    retryStrategy: (attempt) => (attempt > 20 ? null : Math.min(attempt * 200, 2000))
  });

  connection.on('error', (err) => {
    logger.error('redis connection error', { code: err.code, message: err.message });
  });

  return connection;
}

export function createQueue(connection) {
  return new Queue(config.queueName, {
    connection,
    defaultJobOptions: {
      attempts: 2,
      removeOnComplete: 500,
      removeOnFail: 200,
      backoff: { type: 'exponential', delay: 500 }
    }
  });
}
