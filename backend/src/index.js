require('dotenv').config();
const http = require('http');
const app = require('./app');
const { initDB } = require('./config/database');
const { initRedis } = require('./config/redis');
const { initSocketIO } = require('./config/socket');
const logger = require('./utils/logger');

const PORT = process.env.PORT || 3000;

async function start() {
  try {
    await initDB();
    await initRedis();

    const server = http.createServer(app);
    initSocketIO(server);

    server.listen(PORT, () => {
      logger.info(`DevOpsUnify API running on port ${PORT} [${process.env.NODE_ENV}]`);
    });
  } catch (err) {
    logger.error('Fatal startup error:', err);
    process.exit(1);
  }
}

start();
