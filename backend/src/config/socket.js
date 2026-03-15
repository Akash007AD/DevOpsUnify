const { Server } = require('socket.io');
const logger = require('../utils/logger');

let io;

function initSocketIO(server) {
  io = new Server(server, {
    cors: {
      origin: process.env.FRONTEND_URL || 'http://localhost:5173',
      methods: ['GET', 'POST'],
    },
  });

  io.on('connection', (socket) => {
    logger.info(`Socket connected: ${socket.id}`);

    // Client subscribes to a specific build's log stream
    socket.on('subscribe:build', (buildId) => {
      socket.join(`build:${buildId}`);
      logger.info(`Socket ${socket.id} subscribed to build:${buildId}`);
    });

    socket.on('unsubscribe:build', (buildId) => {
      socket.leave(`build:${buildId}`);
    });

    socket.on('disconnect', () => {
      logger.info(`Socket disconnected: ${socket.id}`);
    });
  });

  logger.info('Socket.IO initialised');
}

function getIO() {
  if (!io) throw new Error('Socket.IO not initialised');
  return io;
}

// Emit a log line to all clients watching a build
function emitBuildLog(buildId, line) {
  if (!io) return;
  io.to(`build:${buildId}`).emit('build:log', { buildId, line, ts: Date.now() });
}

function emitBuildStatus(buildId, status) {
  if (!io) return;
  io.to(`build:${buildId}`).emit('build:status', { buildId, status, ts: Date.now() });
}

module.exports = { initSocketIO, getIO, emitBuildLog, emitBuildStatus };
