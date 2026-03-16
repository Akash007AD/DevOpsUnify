#!/bin/bash
# DevOpsUnify — Apply all fixes
# Run this from your project root: ~/Downloads/devopsunify/
# Usage: bash apply-fixes.sh

set -e
echo "✅ Applying DevOpsUnify fixes..."

# ─────────────────────────────────────────────────────────────────────────────
# 1. backend/src/app.js  — adds /metrics endpoint + prom-client tracking
# ─────────────────────────────────────────────────────────────────────────────
cat > backend/src/app.js << 'EOF'
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
EOF
echo "  ✔ backend/src/app.js"

# ─────────────────────────────────────────────────────────────────────────────
# 2. backend/src/routes/pipelines.js  — duplicate project check + build failure fix
# ─────────────────────────────────────────────────────────────────────────────
cat > backend/src/routes/pipelines.js << 'EOF'
const router = require('express').Router();
const { authenticate } = require('../middleware/auth');
const { Project, Build } = require('../models');
const repoAnalyser = require('../services/repoAnalyser');
const jenkinsfileGenerator = require('../services/jenkinsfileGenerator');
const jenkinsService = require('../services/jenkinsService');
const githubService = require('../services/githubService');
const grafanaService = require('../services/grafanaService');
const { emitBuildLog, emitBuildStatus } = require('../config/socket');
const logger = require('../utils/logger');

// ── List projects ──────────────────────────────────────────────────────────
router.get('/projects', authenticate, async (req, res, next) => {
  try {
    const projects = await Project.findAll({
      where: { userId: req.user.id },
      include: [{ model: Build, limit: 1, order: [['createdAt', 'DESC']] }],
      order: [['createdAt', 'DESC']],
    });
    res.json(projects);
  } catch (err) { next(err); }
});

// ── Create project (full onboarding) ──────────────────────────────────────
router.post('/projects', authenticate, async (req, res, next) => {
  try {
    const { repoUrl, branch = 'main', name } = req.body;
    if (!repoUrl) return res.status(400).json({ error: 'repoUrl required' });

    const repoFullName = repoUrl.replace('https://github.com/', '').replace('.git', '');

    // ── Duplicate check ────────────────────────────────────────────────────
    const existing = await Project.findOne({
      where: { userId: req.user.id, repoFullName, branch },
    });
    if (existing) {
      return res.status(409).json({
        error: `Project for ${repoFullName} (${branch}) already exists`,
        projectId: existing.id,
      });
    }

    // 1. Analyse repo
    const analysis = await repoAnalyser.analyse(repoUrl, req.user.accessToken, branch);
    const projectName = (name || repoUrl.split('/').pop().replace('.git', '')).toLowerCase().replace(/[^a-z0-9-]/g, '-');
    const [owner, repo] = repoFullName.split('/');

    // 2. Create project record
    const project = await Project.create({
      userId: req.user.id,
      name: projectName,
      repoUrl,
      repoFullName,
      branch,
      projectType: analysis.projectType,
      port: analysis.port,
      ecrRepo: projectName,
      helmReleaseName: projectName,
      k8sNamespace: 'default',
      sonarProjectKey: projectName,
      status: 'pending',
    });

    // 3. Register GitHub webhook
    await githubService.registerWebhook(req.user.accessToken, owner, repo).catch(e =>
      logger.warn(`Webhook registration failed: ${e.message}`)
    );

    // 4. Generate and push Jenkinsfile to Jenkins
    const jenkinsfile = jenkinsfileGenerator.generate({
      projectName,
      repoUrl,
      branch,
      projectType: analysis.projectType,
      ecrRegistry: process.env.ECR_REGISTRY,
      ecrRepo: projectName,
      awsRegion: process.env.AWS_REGION,
      sonarProjectKey: projectName,
      helmReleaseName: projectName,
      k8sNamespace: 'default',
      port: analysis.port,
    });

    await jenkinsService.createJob(projectName, jenkinsfile).catch(e =>
      logger.warn(`Jenkins job creation failed (Jenkins not ready): ${e.message}`)
    );

    // 5. Create Grafana dashboard
    const dash = await grafanaService.createDashboard(projectName, analysis.projectType).catch(e => {
      logger.warn(`Grafana dashboard creation failed: ${e.message}`);
      return null;
    });

    await project.update({
      status: 'active',
      grafanaDashboardUid: dash?.uid,
    });

    res.status(201).json({ project, analysis, jenkinsfile });
  } catch (err) { next(err); }
});

// ── Get single project ─────────────────────────────────────────────────────
router.get('/projects/:id', authenticate, async (req, res, next) => {
  try {
    const project = await Project.findOne({
      where: { id: req.params.id, userId: req.user.id },
      include: [{ model: Build, order: [['createdAt', 'DESC']], limit: 10 }],
    });
    if (!project) return res.status(404).json({ error: 'Project not found' });
    res.json(project);
  } catch (err) { next(err); }
});

// ── Trigger manual build ───────────────────────────────────────────────────
router.post('/projects/:id/builds', authenticate, async (req, res, next) => {
  try {
    const project = await Project.findOne({ where: { id: req.params.id, userId: req.user.id } });
    if (!project) return res.status(404).json({ error: 'Project not found' });

    const build = await Build.create({
      projectId: project.id,
      triggeredBy: req.user.login,
      status: 'queued',
    });

    // Try to trigger Jenkins — if it fails, mark the build as failed immediately
    let queueUrl;
    try {
      const result = await jenkinsService.triggerBuild(project.name);
      queueUrl = result.queueUrl;
    } catch (jenkinsErr) {
      logger.error(`Jenkins trigger failed for ${project.name}: ${jenkinsErr.message}`);
      await build.update({
        status: 'failure',
        finishedAt: new Date(),
        logs: `Jenkins error: ${jenkinsErr.message}\n\nMake sure the Jenkins job "${project.name}" exists and Jenkins is reachable at ${process.env.JENKINS_URL}`,
      });
      emitBuildStatus(build.id, 'failure');
      return res.status(202).json({ build, warning: 'Jenkins unreachable — build marked as failed' });
    }

    // Async: resolve build number and stream logs
    _trackBuild(build, project, queueUrl).catch(e => logger.error('Build tracking error:', e));

    res.status(202).json({ build });
  } catch (err) { next(err); }
});

// ── Get builds for a project ───────────────────────────────────────────────
router.get('/projects/:id/builds', authenticate, async (req, res, next) => {
  try {
    const builds = await Build.findAll({
      where: { projectId: req.params.id },
      order: [['createdAt', 'DESC']],
      limit: 20,
    });
    res.json(builds);
  } catch (err) { next(err); }
});

// ── Get single build ───────────────────────────────────────────────────────
router.get('/projects/:id/builds/:buildId', authenticate, async (req, res, next) => {
  try {
    const build = await Build.findOne({ where: { id: req.params.buildId, projectId: req.params.id } });
    if (!build) return res.status(404).json({ error: 'Build not found' });
    res.json(build);
  } catch (err) { next(err); }
});

// ── Get generated Jenkinsfile ──────────────────────────────────────────────
router.get('/projects/:id/jenkinsfile', authenticate, async (req, res, next) => {
  try {
    const project = await Project.findOne({ where: { id: req.params.id, userId: req.user.id } });
    if (!project) return res.status(404).json({ error: 'Project not found' });

    const jenkinsfile = jenkinsfileGenerator.generate({
      projectName: project.name,
      repoUrl: project.repoUrl,
      branch: project.branch,
      projectType: project.projectType,
      ecrRegistry: process.env.ECR_REGISTRY,
      ecrRepo: project.ecrRepo,
      awsRegion: process.env.AWS_REGION,
      sonarProjectKey: project.sonarProjectKey,
      helmReleaseName: project.helmReleaseName,
      k8sNamespace: project.k8sNamespace,
      port: project.port,
    });

    res.json({ jenkinsfile });
  } catch (err) { next(err); }
});

// ── Internal: track build status + stream logs via Socket.IO ──────────────
async function _trackBuild(build, project, queueUrl) {
  try {
    const buildNumber = await jenkinsService.getBuildNumberFromQueue(queueUrl);
    await build.update({ jenkinsBuildNumber: buildNumber, status: 'running', startedAt: new Date() });
    emitBuildStatus(build.id, 'running');

    let logStart = 0;
    let running = true;

    while (running) {
      await new Promise(r => setTimeout(r, 3000));

      const { text, moreData, nextStart } = await jenkinsService.getConsoleLog(project.name, buildNumber, logStart);
      if (text) {
        await build.update({ logs: build.logs + text });
        for (const line of text.split('\n')) {
          emitBuildLog(build.id, line);
        }
        logStart = nextStart;
      }

      const status = await jenkinsService.getBuildStatus(project.name, buildNumber);
      if (!status.building) {
        running = false;
        const finalStatus = status.result === 'SUCCESS' ? 'success' : 'failure';
        await build.update({
          status: finalStatus,
          finishedAt: new Date(),
          duration: Math.round(status.duration / 1000),
          jenkinsBuildUrl: status.url,
        });
        emitBuildStatus(build.id, finalStatus);
      }
    }
  } catch (err) {
    logger.error('_trackBuild error:', err);
    await build.update({ status: 'failure', finishedAt: new Date() });
    emitBuildStatus(build.id, 'failure');
  }
}

module.exports = router;
EOF
echo "  ✔ backend/src/routes/pipelines.js"

# ─────────────────────────────────────────────────────────────────────────────
# 3. backend/src/services/jenkinsService.js  — fix URL helper, no more double-slash bugs
# ─────────────────────────────────────────────────────────────────────────────
cat > backend/src/services/jenkinsService.js << 'EOF'
const axios = require('axios');
const yaml = require('yaml');
const fs = require('fs');
const path = require('path');
const logger = require('../utils/logger');

const JENKINS_URL   = () => (process.env.JENKINS_URL || '').replace(/\/$/, '');
const JENKINS_USER  = () => process.env.JENKINS_USER;
const JENKINS_TOKEN = () => process.env.JENKINS_API_TOKEN;

function auth() {
  return { username: JENKINS_USER(), password: JENKINS_TOKEN() };
}

function apiUrl(p) {
  return `${JENKINS_URL()}${p}`;
}

class JenkinsService {
  // ── Crumb (CSRF token) ────────────────────────────────────────────────────
  async _getCrumb() {
    const res = await axios.get(apiUrl('/crumbIssuer/api/json'), { auth: auth() });
    return { [res.data.crumbRequestField]: res.data.crumb };
  }

  // ── Create or update a pipeline job ───────────────────────────────────────
  async createJob(jobName, jenkinsfileContent) {
    const configXml = this._buildJobConfigXml(jobName, jenkinsfileContent);
    const crumb = await this._getCrumb();
    const headers = { 'Content-Type': 'application/xml', ...crumb };

    try {
      await axios.post(
        apiUrl(`/createItem?name=${encodeURIComponent(jobName)}`),
        configXml,
        { auth: auth(), headers }
      );
      logger.info(`Jenkins job created: ${jobName}`);
    } catch (err) {
      if (err.response?.status === 400) {
        await axios.post(
          apiUrl(`/job/${encodeURIComponent(jobName)}/config.xml`),
          configXml,
          { auth: auth(), headers }
        );
        logger.info(`Jenkins job updated: ${jobName}`);
      } else {
        throw err;
      }
    }
  }

  // ── Trigger a build ────────────────────────────────────────────────────────
  async triggerBuild(jobName, params = {}) {
    const crumb = await this._getCrumb();
    const hasParams = Object.keys(params).length > 0;
    const url = hasParams
      ? apiUrl(`/job/${encodeURIComponent(jobName)}/buildWithParameters`)
      : apiUrl(`/job/${encodeURIComponent(jobName)}/build`);

    const res = await axios.post(url, null, {
      auth: auth(),
      headers: crumb,
      params: hasParams ? params : undefined,
    });

    const queueUrl = res.headers['location'];
    return { queueUrl };
  }

  // ── Poll queue item → get build number ───────────────────────────────────
  async getBuildNumberFromQueue(queueUrl, maxWaitMs = 30000) {
    const deadline = Date.now() + maxWaitMs;
    while (Date.now() < deadline) {
      const res = await axios.get(`${queueUrl}api/json`, { auth: auth() });
      if (res.data.executable?.number) {
        return res.data.executable.number;
      }
      await new Promise(r => setTimeout(r, 2000));
    }
    throw new Error('Timed out waiting for Jenkins build number');
  }

  // ── Get build status ───────────────────────────────────────────────────────
  async getBuildStatus(jobName, buildNumber) {
    const res = await axios.get(
      apiUrl(`/job/${encodeURIComponent(jobName)}/${buildNumber}/api/json`),
      { auth: auth() }
    );
    return {
      building: res.data.building,
      result: res.data.result,
      duration: res.data.duration,
      url: res.data.url,
    };
  }

  // ── Stream console log ─────────────────────────────────────────────────────
  async getConsoleLog(jobName, buildNumber, start = 0) {
    const res = await axios.get(
      apiUrl(`/job/${encodeURIComponent(jobName)}/${buildNumber}/logText/progressiveText`),
      {
        auth: auth(),
        params: { start },
        responseType: 'text',
      }
    );
    return {
      text: res.data,
      moreData: res.headers['x-more-data'] === 'true',
      nextStart: parseInt(res.headers['x-text-size'] || '0'),
    };
  }

  // ── Set up GitHub webhook on job ───────────────────────────────────────────
  async configureGithubTrigger(jobName, secret) {
    logger.info(`GitHub trigger configured for ${jobName}`);
  }

  // ── Build job config XML ───────────────────────────────────────────────────
  _buildJobConfigXml(jobName, jenkinsfileContent) {
    const escaped = jenkinsfileContent
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;');

    return `<?xml version='1.1' encoding='UTF-8'?>
<flow-definition plugin="workflow-job">
  <description>Auto-generated by DevOpsUnify for ${jobName}</description>
  <keepDependencies>false</keepDependencies>
  <properties>
    <org.jenkinsci.plugins.workflow.job.properties.PipelineTriggersJobProperty>
      <triggers>
        <com.cloudbees.jenkins.GitHubPushTrigger plugin="github">
          <spec></spec>
        </com.cloudbees.jenkins.GitHubPushTrigger>
      </triggers>
    </org.jenkinsci.plugins.workflow.job.properties.PipelineTriggersJobProperty>
  </properties>
  <definition class="org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition" plugin="workflow-cps">
    <script>${escaped}</script>
    <sandbox>true</sandbox>
  </definition>
  <triggers/>
  <disabled>false</disabled>
</flow-definition>`;
  }
}

module.exports = new JenkinsService();
EOF
echo "  ✔ backend/src/services/jenkinsService.js"

# ─────────────────────────────────────────────────────────────────────────────
# 4. backend/package.json  — add prom-client dependency
# ─────────────────────────────────────────────────────────────────────────────
cat > backend/package.json << 'EOF'
{
  "name": "devopsunify-backend",
  "version": "1.0.0",
  "description": "DevOpsUnify API Server",
  "main": "src/index.js",
  "scripts": {
    "start": "node src/index.js",
    "dev": "nodemon src/index.js",
    "test": "jest --coverage",
    "lint": "eslint src/"
  },
  "dependencies": {
    "@octokit/rest": "^20.0.2",
    "axios": "^1.6.7",
    "bcryptjs": "^2.4.3",
    "bull": "^4.12.2",
    "cors": "^2.8.5",
    "dotenv": "^16.4.1",
    "express": "^4.18.2",
    "express-rate-limit": "^7.1.5",
    "express-validator": "^7.0.1",
    "helmet": "^7.1.0",
    "ioredis": "^5.3.2",
    "jsonwebtoken": "^9.0.2",
    "morgan": "^1.10.0",
    "pg": "^8.11.3",
    "prom-client": "^15.1.0",
    "sequelize": "^6.36.0",
    "simple-git": "^3.22.0",
    "socket.io": "^4.6.2",
    "uuid": "^9.0.0",
    "winston": "^3.11.0",
    "yaml": "^2.4.1"
  },
  "devDependencies": {
    "eslint": "^8.57.0",
    "jest": "^29.7.0",
    "nodemon": "^3.0.3",
    "supertest": "^6.3.4"
  }
}
EOF
echo "  ✔ backend/package.json"

# ─────────────────────────────────────────────────────────────────────────────
# 5. frontend/src/pages/InfraPage.jsx  — fix duplicate API calls with useRef guard
# ─────────────────────────────────────────────────────────────────────────────
cat > frontend/src/pages/InfraPage.jsx << 'EOF'
import React, { useEffect, useState, useRef } from 'react';
import api from '../utils/api';
import { ArrowPathIcon, ServerStackIcon, TrashIcon } from '@heroicons/react/24/outline';

export default function InfraPage() {
  const [projects, setProjects]   = useState([]);
  const [infraMap, setInfraMap]   = useState({});
  const [loading, setLoading]     = useState(true);
  const [provisioning, setProv]   = useState({});
  const fetchedRef = useRef(false);

  useEffect(() => {
    if (fetchedRef.current) return;
    fetchedRef.current = true;

    api.get('/pipelines/projects').then(async r => {
      setProjects(r.data);
      const map = {};
      await Promise.all(r.data.map(async p => {
        try {
          const ir = await api.get(`/infra/projects/${p.id}/infra`);
          map[p.id] = ir.data[0] || null;
        } catch (_) { map[p.id] = null; }
      }));
      setInfraMap(map);
    }).finally(() => setLoading(false));
  }, []);

  async function provision(projectId) {
    setProv(prev => ({ ...prev, [projectId]: 'provisioning' }));
    try {
      await api.post(`/infra/projects/${projectId}/provision`);
      setProv(prev => ({ ...prev, [projectId]: 'done' }));
    } catch (e) {
      setProv(prev => ({ ...prev, [projectId]: 'error' }));
    }
  }

  async function destroy(projectId) {
    if (!window.confirm('Destroy all AWS resources for this project? This cannot be undone.')) return;
    setProv(prev => ({ ...prev, [projectId]: 'destroying' }));
    try {
      await api.delete(`/infra/projects/${projectId}/infra`);
      setProv(prev => ({ ...prev, [projectId]: 'done' }));
    } catch (_) {
      setProv(prev => ({ ...prev, [projectId]: 'error' }));
    }
  }

  const STATUS_BADGE = {
    applied:    'badge-success',
    applying:   'badge-running',
    pending:    'badge-queued',
    failed:     'badge-failure',
    destroyed:  'badge-queued',
    destroying: 'badge-running',
  };

  return (
    <div className="space-y-5">
      <div>
        <h1 className="text-xl font-semibold text-white">Infrastructure</h1>
        <p className="text-sm text-gray-500 mt-0.5">Terraform-managed AWS resources per project</p>
      </div>

      <div className="card overflow-hidden p-0">
        <table className="w-full text-sm">
          <thead>
            <tr className="border-b border-gray-800 text-xs text-gray-500 uppercase tracking-wider">
              <th className="text-left px-5 py-3">Project</th>
              <th className="text-left px-5 py-3">Status</th>
              <th className="text-left px-5 py-3">Outputs</th>
              <th className="text-right px-5 py-3">Actions</th>
            </tr>
          </thead>
          <tbody>
            {loading ? (
              <tr><td colSpan={4} className="px-5 py-6 text-gray-500">Loading…</td></tr>
            ) : projects.map(p => {
              const infra = infraMap[p.id];
              const busy  = ['provisioning', 'destroying'].includes(provisioning[p.id]);
              return (
                <tr key={p.id} className="border-b border-gray-800 last:border-0 hover:bg-gray-800/40">
                  <td className="px-5 py-3">
                    <p className="font-medium text-gray-200">{p.name}</p>
                    <p className="text-xs text-gray-500">{p.projectType}</p>
                  </td>
                  <td className="px-5 py-3">
                    {infra
                      ? <span className={STATUS_BADGE[infra.status] || 'badge-queued'}>{infra.status}</span>
                      : <span className="badge-queued">not provisioned</span>
                    }
                  </td>
                  <td className="px-5 py-3">
                    {infra?.outputs && Object.keys(infra.outputs).length > 0 ? (
                      <div className="text-xs text-gray-500 space-y-0.5">
                        {Object.entries(infra.outputs).slice(0, 3).map(([k, v]) => (
                          <div key={k}><span className="text-gray-400">{k}:</span> {String(v).slice(0, 40)}</div>
                        ))}
                      </div>
                    ) : <span className="text-gray-600 text-xs">–</span>}
                  </td>
                  <td className="px-5 py-3 text-right">
                    <div className="flex items-center justify-end gap-2">
                      {(!infra || infra.status === 'destroyed' || infra.status === 'failed') && (
                        <button className="btn-primary py-1.5 px-3 text-xs" onClick={() => provision(p.id)} disabled={busy}>
                          {busy ? <ArrowPathIcon className="w-3.5 h-3.5 animate-spin" /> : <ServerStackIcon className="w-3.5 h-3.5" />}
                          {provisioning[p.id] === 'provisioning' ? 'Provisioning…' : 'Provision'}
                        </button>
                      )}
                      {infra?.status === 'applied' && (
                        <button className="btn-secondary py-1.5 px-3 text-xs text-red-400" onClick={() => destroy(p.id)} disabled={busy}>
                          <TrashIcon className="w-3.5 h-3.5" />
                          {provisioning[p.id] === 'destroying' ? 'Destroying…' : 'Destroy'}
                        </button>
                      )}
                    </div>
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
    </div>
  );
}
EOF
echo "  ✔ frontend/src/pages/InfraPage.jsx"

# ─────────────────────────────────────────────────────────────────────────────
# 6. frontend/src/pages/NewProjectPage.jsx  — handle 409 duplicate gracefully
# ─────────────────────────────────────────────────────────────────────────────
cat > frontend/src/pages/NewProjectPage.jsx << 'EOF'
import React, { useEffect, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import api from '../utils/api';
import { MagnifyingGlassIcon, ArrowPathIcon, CheckIcon } from '@heroicons/react/24/outline';

function AnalysisResult({ result }) {
  if (!result) return null;
  const { projectType, buildTool, port, hasDockerfile } = result;
  return (
    <div className="mt-4 p-4 bg-green-900/20 border border-green-800 rounded-lg space-y-1">
      <p className="text-sm font-medium text-green-400 flex items-center gap-2"><CheckIcon className="w-4 h-4" /> Repository analysed successfully</p>
      <div className="grid grid-cols-2 gap-2 mt-2 text-xs text-gray-400">
        <span>Type: <strong className="text-gray-200">{projectType}</strong></span>
        <span>Build tool: <strong className="text-gray-200">{buildTool}</strong></span>
        <span>Port: <strong className="text-gray-200">{port}</strong></span>
        <span>Has Dockerfile: <strong className="text-gray-200">{hasDockerfile ? 'Yes' : 'No (will generate)'}</strong></span>
      </div>
    </div>
  );
}

export default function NewProjectPage() {
  const [repos, setRepos] = useState([]);
  const [search, setSearch] = useState('');
  const [selectedRepo, setSelectedRepo] = useState(null);
  const [branch, setBranch] = useState('main');
  const [branches, setBranches] = useState([]);
  const [analysis, setAnalysis] = useState(null);
  const [analysing, setAnalysing] = useState(false);
  const [creating, setCreating] = useState(false);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const navigate = useNavigate();

  useEffect(() => {
    api.get('/repos').then(r => setRepos(r.data)).finally(() => setLoading(false));
  }, []);

  async function handleSelectRepo(repo) {
    setSelectedRepo(repo);
    setAnalysis(null);
    setError('');
    const [owner, repoName] = repo.fullName.split('/');
    const br = await api.get(`/repos/${owner}/${repoName}/branches`).then(r => r.data).catch(() => ['main']);
    setBranches(br);
    setBranch(repo.defaultBranch || 'main');
  }

  async function handleAnalyse() {
    if (!selectedRepo) return;
    setAnalysing(true);
    setError('');
    try {
      const { data } = await api.post('/repos/analyse', { repoUrl: selectedRepo.cloneUrl, branch });
      setAnalysis(data);
    } catch (e) {
      setError(e.response?.data?.error || 'Analysis failed');
    } finally {
      setAnalysing(false);
    }
  }

  async function handleCreate() {
    if (!selectedRepo || !analysis) return;
    setCreating(true);
    setError('');
    try {
      const { data } = await api.post('/pipelines/projects', {
        repoUrl: selectedRepo.cloneUrl,
        branch,
        name: selectedRepo.name,
      });
      navigate(`/projects/${data.project.id}`);
    } catch (e) {
      if (e.response?.status === 409) {
        // Already exists — navigate to the existing project
        const existingId = e.response.data?.projectId;
        if (existingId) {
          navigate(`/projects/${existingId}`);
        } else {
          setError('A project for this repository and branch already exists.');
        }
      } else {
        setError(e.response?.data?.error || 'Project creation failed');
      }
      setCreating(false);
    }
  }

  const filtered = repos.filter(r =>
    r.fullName.toLowerCase().includes(search.toLowerCase())
  );

  return (
    <div className="max-w-2xl mx-auto space-y-6">
      <div>
        <h1 className="text-xl font-semibold text-white">New Project</h1>
        <p className="text-sm text-gray-500 mt-0.5">Select a GitHub repository to onboard</p>
      </div>

      {/* Step 1 — Pick repo */}
      <div className="card space-y-3">
        <h2 className="text-sm font-semibold text-gray-300">1. Select repository</h2>
        <div className="relative">
          <MagnifyingGlassIcon className="absolute left-3 top-2.5 w-4 h-4 text-gray-500" />
          <input
            className="w-full bg-gray-800 border border-gray-700 rounded-lg pl-9 pr-4 py-2 text-sm text-gray-200 placeholder-gray-500 focus:outline-none focus:border-brand-500"
            placeholder="Search repositories…"
            value={search}
            onChange={e => setSearch(e.target.value)}
          />
        </div>
        <div className="max-h-56 overflow-y-auto space-y-1 -mx-1 px-1">
          {loading ? (
            <p className="text-gray-500 text-sm py-2">Loading repos…</p>
          ) : filtered.map(r => (
            <button
              key={r.id}
              onClick={() => handleSelectRepo(r)}
              className={`w-full text-left px-3 py-2.5 rounded-lg text-sm transition-colors flex items-center gap-3
                ${selectedRepo?.id === r.id
                  ? 'bg-brand-600/20 text-brand-400 border border-brand-600/40'
                  : 'text-gray-300 hover:bg-gray-800'}`}
            >
              <span className="flex-1 truncate">{r.fullName}</span>
              <span className="text-xs text-gray-600 shrink-0">{r.language || 'unknown'}</span>
              {r.private && <span className="text-xs text-gray-600">private</span>}
            </button>
          ))}
        </div>
      </div>

      {/* Step 2 — Branch + analyse */}
      {selectedRepo && (
        <div className="card space-y-3">
          <h2 className="text-sm font-semibold text-gray-300">2. Select branch &amp; analyse</h2>
          <div className="flex gap-3">
            <select
              value={branch}
              onChange={e => setBranch(e.target.value)}
              className="flex-1 bg-gray-800 border border-gray-700 rounded-lg px-3 py-2 text-sm text-gray-200 focus:outline-none focus:border-brand-500"
            >
              {branches.map(b => <option key={b} value={b}>{b}</option>)}
            </select>
            <button className="btn-secondary" onClick={handleAnalyse} disabled={analysing}>
              {analysing ? <ArrowPathIcon className="w-4 h-4 animate-spin" /> : null}
              {analysing ? 'Analysing…' : 'Analyse Repo'}
            </button>
          </div>
          <AnalysisResult result={analysis} />
        </div>
      )}

      {/* Step 3 — Create */}
      {analysis && (
        <div className="card space-y-3">
          <h2 className="text-sm font-semibold text-gray-300">3. Create project</h2>
          <p className="text-xs text-gray-500">
            This will: register a GitHub webhook, generate a Jenkinsfile, create an ECR config, and provision a Grafana dashboard.
          </p>
          {error && <p className="text-sm text-red-400">{error}</p>}
          <button className="btn-primary w-full justify-center" onClick={handleCreate} disabled={creating}>
            {creating ? <ArrowPathIcon className="w-4 h-4 animate-spin" /> : <CheckIcon className="w-4 h-4" />}
            {creating ? 'Creating project…' : 'Create Project'}
          </button>
        </div>
      )}

      {error && !analysis && <p className="text-sm text-red-400">{error}</p>}
    </div>
  );
}
EOF
echo "  ✔ frontend/src/pages/NewProjectPage.jsx"

# ─────────────────────────────────────────────────────────────────────────────
# 7. docker-compose.yml  — remove version warning, add missing env vars
# ─────────────────────────────────────────────────────────────────────────────
cat > docker-compose.yml << 'EOF'
# =============================================================================
# DevOpsUnify — Local Docker Compose Stack
# Usage:
#   docker compose up -d            # Start all services
#   docker compose up -d backend    # Start only backend + deps
#   docker compose logs -f backend  # Tail logs
#   docker compose down -v          # Stop and remove volumes
# =============================================================================

services:
  # ── Infrastructure ─────────────────────────────────────────────────────────
  postgres:
    image: postgres:15-alpine
    restart: unless-stopped
    environment:
      POSTGRES_DB:       devopsunify
      POSTGRES_USER:     devopsunify
      POSTGRES_PASSWORD: devopsunify_pass
    ports:
      - "5432:5432"
    volumes:
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U devopsunify"]
      interval: 10s
      timeout: 5s
      retries: 5

  redis:
    image: redis:7-alpine
    restart: unless-stopped
    ports:
      - "6379:6379"
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s

  # ── Application ────────────────────────────────────────────────────────────
  backend:
    build:
      context: ./backend
      dockerfile: Dockerfile
    extra_hosts:
      - "host.docker.internal:host-gateway"
    restart: unless-stopped
    ports:
      - "3000:3000"
    environment:
      NODE_ENV:              development
      PORT:                  3000
      DB_HOST:               postgres
      DB_PORT:               5432
      DB_NAME:               devopsunify
      DB_USER:               devopsunify
      DB_PASS:               devopsunify_pass
      REDIS_HOST:            redis
      REDIS_PORT:            6379
      JWT_SECRET:            74aa2bec49926c949f468d439dcf04b8a9d68757f63dc6623e7b532c8ed877f
      GITHUB_CLIENT_ID:      Ov23ligpEdcN3CKzkonL
      GITHUB_CLIENT_SECRET:  724a6702b25b833d07860ef22ce5bf1c11dc4492
      GITHUB_CALLBACK_URL:   http://localhost:3000/api/auth/github/callback
      GITHUB_WEBHOOK_SECRET: dc20181f6e39d33558cc186d13fe4b6a8c0f8b405a333c1384854e127cca6c811
      JENKINS_URL:           http://host.docker.internal:8080
      JENKINS_USER:          Akash
      JENKINS_API_TOKEN:     117076005d776a45714e3308bb057f836e
      BACKEND_URL:           http://host.docker.internal:3000
      SONAR_URL:             http://sonarqube:9000
      SONAR_TOKEN:           ${SONAR_TOKEN:-}
      GRAFANA_URL:           http://grafana:3001
      GRAFANA_API_KEY:       ${GRAFANA_API_KEY:-}
      FRONTEND_URL:          http://localhost:5173
      AWS_REGION:            ${AWS_REGION:-ap-south-1}
      ECR_REGISTRY:          ${ECR_REGISTRY:-}
    volumes:
      - ./backend/src:/app/src
      - backend-logs:/app/logs
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://localhost:3000/health || exit 1"]
      interval: 30s
      start_period: 15s

  frontend:
    build:
      context: ./frontend
      dockerfile: Dockerfile
    restart: unless-stopped
    ports:
      - "5173:80"
    depends_on:
      - backend

  # ── CI/CD ──────────────────────────────────────────────────────────────────
  jenkins:
    image: jenkins/jenkins:lts-jdk17
    restart: unless-stopped
    privileged: true
    user: root
    ports:
      - "8080:8080"
      - "50000:50000"
    environment:
      JAVA_OPTS: "-Djenkins.install.runSetupWizard=false"
      JENKINS_OPTS: "--prefix=/jenkins"
    volumes:
      - jenkins-home:/var/jenkins_home
      - /var/run/docker.sock:/var/run/docker.sock
    healthcheck:
      test: ["CMD-SHELL", "curl -sf http://localhost:8080/jenkins/login || exit 1"]
      interval: 30s
      start_period: 60s

  # ── Code Quality ───────────────────────────────────────────────────────────
  sonarqube:
    image: sonarqube:10-community
    restart: unless-stopped
    ports:
      - "9000:9000"
    environment:
      SONAR_JDBC_URL:      jdbc:postgresql://postgres:5432/sonar
      SONAR_JDBC_USERNAME: devopsunify
      SONAR_JDBC_PASSWORD: devopsunify_pass
    volumes:
      - sonar-data:/opt/sonarqube/data
      - sonar-logs:/opt/sonarqube/logs
      - sonar-extensions:/opt/sonarqube/extensions
    ulimits:
      nofile:
        soft: 65536
        hard: 65536
    depends_on:
      postgres:
        condition: service_healthy

  # ── Monitoring ─────────────────────────────────────────────────────────────
  prometheus:
    image: prom/prometheus:v2.50.0
    restart: unless-stopped
    ports:
      - "9090:9090"
    command:
      - "--config.file=/etc/prometheus/prometheus.yml"
      - "--storage.tsdb.path=/prometheus"
      - "--storage.tsdb.retention.time=15d"
      - "--web.enable-lifecycle"
    volumes:
      - ./docker/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prometheus-data:/prometheus

  grafana:
    image: grafana/grafana:10.3.1
    restart: unless-stopped
    ports:
      - "3001:3000"
    environment:
      GF_SECURITY_ADMIN_USER:     admin
      GF_SECURITY_ADMIN_PASSWORD: DevOpsUnify2024
      GF_SERVER_HTTP_PORT:        3000
      GF_USERS_ALLOW_SIGN_UP:     "false"
      GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH: /var/lib/grafana/dashboards/devopsunify.json
    volumes:
      - grafana-data:/var/lib/grafana
      - ./docker/grafana/provisioning:/etc/grafana/provisioning
    depends_on:
      - prometheus

volumes:
  pgdata:
  backend-logs:
  jenkins-home:
  sonar-data:
  sonar-logs:
  sonar-extensions:
  prometheus-data:
  grafana-data:

networks:
  default:
    name: devopsunify-network
EOF
echo "  ✔ docker-compose.yml"

echo ""
echo "✅ All files updated! Now rebuild and restart:"
echo ""
echo "  docker compose down"
echo "  docker compose build backend"
echo "  docker compose up -d"
echo ""
echo "  Then verify /metrics is working:"
echo "  curl http://localhost:3000/metrics | head -20"
