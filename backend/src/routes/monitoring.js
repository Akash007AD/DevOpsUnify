const router = require('express').Router();
const axios = require('axios');
const { authenticate } = require('../middleware/auth');
const { Project } = require('../models');
const grafanaService = require('../services/grafanaService');

// Get Grafana dashboard URL for a project
router.get('/projects/:id/dashboard', authenticate, async (req, res, next) => {
  try {
    const project = await Project.findOne({ where: { id: req.params.id, userId: req.user.id } });
    if (!project) return res.status(404).json({ error: 'Project not found' });

    if (!project.grafanaDashboardUid) {
      return res.status(404).json({ error: 'No dashboard provisioned for this project' });
    }

    const url = await grafanaService.getDashboardUrl(project.grafanaDashboardUid);
    res.json({ url, uid: project.grafanaDashboardUid });
  } catch (err) { next(err); }
});

// Proxy Prometheus instant query
router.get('/prometheus/query', authenticate, async (req, res, next) => {
  try {
    const { query } = req.query;
    if (!query) return res.status(400).json({ error: 'query param required' });

    const resp = await axios.get(`${process.env.PROMETHEUS_URL || 'http://prometheus:9090'}/api/v1/query`, {
      params: { query },
    });
    res.json(resp.data);
  } catch (err) { next(err); }
});

// Get quick pod metrics for a project
router.get('/projects/:id/metrics', authenticate, async (req, res, next) => {
  try {
    const project = await Project.findOne({ where: { id: req.params.id, userId: req.user.id } });
    if (!project) return res.status(404).json({ error: 'Project not found' });

    const promBase = process.env.PROMETHEUS_URL || 'http://prometheus:9090';
    const queries = {
      cpu:    `sum(rate(container_cpu_usage_seconds_total{pod=~"${project.name}-.*"}[5m]))`,
      memory: `sum(container_memory_working_set_bytes{pod=~"${project.name}-.*"})`,
      pods:   `count(kube_pod_info{pod=~"${project.name}-.*"})`,
    };

    const results = {};
    await Promise.all(
      Object.entries(queries).map(async ([key, q]) => {
        try {
          const r = await axios.get(`${promBase}/api/v1/query`, { params: { query: q } });
          results[key] = r.data.data?.result?.[0]?.value?.[1] || 0;
        } catch (_) {
          results[key] = null;
        }
      })
    );

    res.json(results);
  } catch (err) { next(err); }
});

module.exports = router;
