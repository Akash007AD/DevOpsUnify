const Redis = require('ioredis');
const logger = require('../utils/logger');

let redisClient;

async function initRedis() {
  redisClient = new Redis({
    host: process.env.REDIS_HOST || 'localhost',
    port: parseInt(process.env.REDIS_PORT || '6379'),
    password: process.env.REDIS_PASS || undefined,
    retryStrategy: (times) => Math.min(times * 100, 3000),
  });

  redisClient.on('connect', () => logger.info('Redis connected'));
  redisClient.on('error', (err) => logger.error('Redis error:', err));

  await redisClient.ping();
}

function getRedis() {
  if (!redisClient) throw new Error('Redis not initialised');
  return redisClient;
}

module.exports = { initRedis, getRedis };
