const { Sequelize } = require('sequelize');
const logger = require('../utils/logger');

const sequelize = new Sequelize(
  process.env.DB_NAME,
  process.env.DB_USER,
  process.env.DB_PASS,
  {
    host: process.env.DB_HOST,
    port: parseInt(process.env.DB_PORT || '5432'),
    dialect: 'postgres',
    logging: (msg) => logger.debug(msg),
    pool: { max: 10, min: 2, acquire: 30000, idle: 10000 },
  }
);

async function initDB() {
  await sequelize.authenticate();
  // Import all models so they register themselves
  require('../models');
  await sequelize.sync({ alter: process.env.NODE_ENV === 'development' });
  logger.info('PostgreSQL connected and synced');
}

module.exports = { sequelize, initDB };
