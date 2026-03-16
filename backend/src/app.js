const express = require('express');
const cors = require('cors');
const helmet = require('helmet');
const morgan = require('morgan');
const rateLimit = require('express-rate-limit');
const client = require('prom-client');

const authRoutes = require('./routes/auth');
const repoRoutes = require('./routes/repos');
const pipelineRoutes = require('./routes/pipelines');
const infraRoutes = require('./routes/infra');
const monitoringRoutes = require('./routes/monitoring');
const webhookRoutes = require('./routes/webhooks');
const { errorHandler } = require('./middleware/errorHandler');
const logger = require('./utils/logger');

// ── Prometheus metrics setup ───────────────────────────────────────────────
const register = new client.Registry();
client.collectDefaultMetrics({ register });

const httpRequestDuration = new client.Histogram({
  name: 'http_request_duration_seconds',
  help: 'Duration of HTTP requests in seconds',
  labelNames: ['method', 'route', 'status_code'],
  registers: [register],
});

const httpRequestTotal = new client.Counter({
  name: 'http_requests_total',
  help: 'Total number of HTTP requests',
  labelNames: ['method', 'route', 'status_code'],
  registers: [register],
});

const app = express();

// ── Security middlewares ───────────────────────────────────────────────────
app.use(helmet());
app.use(cors({
  origin: process.env.FRONTEND_URL || 'http://localhost:5173',
  credentials: true,
}));

// ── Rate limiting ──────────────────────────────────────────────────────────
const limiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 200,
  standardHeaders: true,
  legacyHeaders: false,
});
app.use('/api/', limiter);

// ── Body parsing ───────────────────────────────────────────────────────────
// Raw body needed for GitHub webhook signature verification
app.use('/api/webhooks/github', express.raw({ type: 'application/json' }));
app.use(express.json({ limit: '10mb' }));
app.use(express.urlencoded({ extended: true }));

// ── Prometheus request tracking ────────────────────────────────────────────
app.use((req, res, next) => {
  const end = httpRequestDuration.startTimer();
  res.on('finish', () => {
    const route = req.route?.path || req.path;
    end({ method: req.method, route, status_code: res.statusCode });
    httpRequestTotal.inc({ method: req.method, route, status_code: res.statusCode });
  });
  next();
});

// ── Logging ────────────────────────────────────────────────────────────────
app.use(morgan('combined', { stream: { write: msg => logger.info(msg.trim()) } }));

// ── Health check ───────────────────────────────────────────────────────────
app.get('/health', (req, res) => res.json({ status: 'ok', ts: new Date() }));

// ── Metrics endpoint for Prometheus ───────────────────────────────────────
app.get('/metrics', async (req, res) => {
  try {
    res.set('Content-Type', register.contentType);
    res.end(await register.metrics());
  } catch (err) {
    res.status(500).end(err.message);
  }
});

// ── Routes ─────────────────────────────────────────────────────────────────
app.use('/api/auth', authRoutes);
app.use('/api/repos', repoRoutes);
app.use('/api/pipelines', pipelineRoutes);
app.use('/api/infra', infraRoutes);
app.use('/api/monitoring', monitoringRoutes);
app.use('/api/webhooks', webhookRoutes);

// ── Error handler (must be last) ───────────────────────────────────────────
app.use(errorHandler);

module.exports = app;
