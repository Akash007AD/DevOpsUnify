#!/bin/bash
# Fix Jenkins 404 — adds sync-jenkins endpoint + Sync Jenkins button in UI
# Run from project root: bash fix-jenkins-404.sh

set -e
echo "✅ Applying Jenkins 404 fix..."

# ─────────────────────────────────────────────────────────────────────────────
# 1. backend/src/routes/pipelines.js  — add /sync-jenkins endpoint
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

// ── Re-sync Jenkins job for an existing project ───────────────────────────
router.post('/projects/:id/sync-jenkins', authenticate, async (req, res, next) => {
  try {
    const project = await Project.findOne({ where: { id: req.params.id, userId: req.user.id } });
    if (!project) return res.status(404).json({ error: 'Project not found' });

    const jenkinsfile = jenkinsfileGenerator.generate({
      projectName:      project.name,
      repoUrl:          project.repoUrl,
      branch:           project.branch,
      projectType:      project.projectType,
      ecrRegistry:      process.env.ECR_REGISTRY,
      ecrRepo:          project.ecrRepo,
      awsRegion:        process.env.AWS_REGION,
      sonarProjectKey:  project.sonarProjectKey,
      helmReleaseName:  project.helmReleaseName,
      k8sNamespace:     project.k8sNamespace,
      port:             project.port,
    });

    await jenkinsService.createJob(project.name, jenkinsfile);
    res.json({ message: `Jenkins job "${project.name}" created/updated successfully` });
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
# 2. frontend/src/pages/ProjectDetail.jsx  — add Sync Jenkins button
# ─────────────────────────────────────────────────────────────────────────────
cat > frontend/src/pages/ProjectDetail.jsx << 'EOF'
import React, { useEffect, useState } from 'react';
import { useParams, Link } from 'react-router-dom';
import api from '../utils/api';
import { ArrowPathIcon, PlayIcon, CodeBracketIcon, ChartBarIcon, ArrowUpTrayIcon } from '@heroicons/react/24/outline';
import { formatDistanceToNow } from 'date-fns';

const STATUS_BADGE = {
  success: 'badge-success',
  failure: 'badge-failure',
  running: 'badge-running',
  queued:  'badge-queued',
  aborted: 'badge-queued',
};

export default function ProjectDetail() {
  const { id } = useParams();
  const [project, setProject]         = useState(null);
  const [builds, setBuilds]           = useState([]);
  const [jenkinsfile, setJenkinsfile] = useState('');
  const [tab, setTab]                 = useState('builds');
  const [triggering, setTriggering]   = useState(false);
  const [syncing, setSyncing]         = useState(false);
  const [syncMsg, setSyncMsg]         = useState('');
  const [loading, setLoading]         = useState(true);

  useEffect(() => {
    Promise.all([
      api.get(`/pipelines/projects/${id}`),
      api.get(`/pipelines/projects/${id}/builds`),
    ]).then(([pr, br]) => {
      setProject(pr.data);
      setBuilds(br.data);
    }).finally(() => setLoading(false));
  }, [id]);

  async function loadJenkinsfile() {
    if (jenkinsfile) return;
    const { data } = await api.get(`/pipelines/projects/${id}/jenkinsfile`);
    setJenkinsfile(data.jenkinsfile);
  }

  async function triggerBuild() {
    setTriggering(true);
    try {
      const { data } = await api.post(`/pipelines/projects/${id}/builds`);
      setBuilds(prev => [data.build, ...prev]);
    } finally {
      setTriggering(false);
    }
  }

  async function syncJenkins() {
    setSyncing(true);
    setSyncMsg('');
    try {
      const { data } = await api.post(`/pipelines/projects/${id}/sync-jenkins`);
      setSyncMsg(data.message);
    } catch (e) {
      setSyncMsg(e.response?.data?.error || 'Sync failed');
    } finally {
      setSyncing(false);
    }
  }

  if (loading) return <div className="text-gray-500 text-sm">Loading…</div>;
  if (!project) return <div className="text-red-400">Project not found</div>;

  return (
    <div className="space-y-5">
      {/* Header */}
      <div className="flex items-start gap-4">
        <div className="w-12 h-12 rounded-xl bg-brand-600/20 flex items-center justify-center text-brand-400 font-bold text-lg uppercase shrink-0">
          {project.name[0]}
        </div>
        <div className="flex-1 min-w-0">
          <div className="flex items-center gap-2 flex-wrap">
            <h1 className="text-xl font-semibold text-white">{project.name}</h1>
            <span className={STATUS_BADGE[project.status] || 'badge-queued'}>{project.status}</span>
          </div>
          <p className="text-sm text-gray-500 mt-0.5">{project.repoFullName} · {project.branch} · {project.projectType}</p>
        </div>
        <div className="flex items-center gap-2 flex-wrap justify-end">
          {project.grafanaDashboardUid && (
            <a href={`${import.meta.env.VITE_GRAFANA_URL || ''}/d/${project.grafanaDashboardUid}`}
              target="_blank" rel="noopener noreferrer" className="btn-secondary">
              <ChartBarIcon className="w-4 h-4" /> Grafana
            </a>
          )}
          <button className="btn-secondary" onClick={syncJenkins} disabled={syncing} title="Push Jenkinsfile to Jenkins">
            {syncing ? <ArrowPathIcon className="w-4 h-4 animate-spin" /> : <ArrowUpTrayIcon className="w-4 h-4" />}
            {syncing ? 'Syncing…' : 'Sync Jenkins'}
          </button>
          <button className="btn-primary" onClick={triggerBuild} disabled={triggering}>
            {triggering ? <ArrowPathIcon className="w-4 h-4 animate-spin" /> : <PlayIcon className="w-4 h-4" />}
            {triggering ? 'Triggering…' : 'Run Build'}
          </button>
        </div>
      </div>

      {/* Sync feedback */}
      {syncMsg && (
        <div className={`text-sm px-4 py-2 rounded-lg ${
          syncMsg.toLowerCase().includes('success') || syncMsg.includes('created') || syncMsg.includes('updated')
            ? 'bg-green-900/20 text-green-400 border border-green-800'
            : 'bg-red-900/20 text-red-400 border border-red-800'
        }`}>
          {syncMsg}
        </div>
      )}

      {/* Info cards */}
      <div className="grid grid-cols-2 lg:grid-cols-4 gap-3">
        {[
          { label: 'ECR Repo',     value: project.ecrRepo || '–' },
          { label: 'Namespace',    value: project.k8sNamespace },
          { label: 'Port',         value: project.port },
          { label: 'Helm Release', value: project.helmReleaseName || '–' },
        ].map(({ label, value }) => (
          <div key={label} className="card py-3">
            <p className="text-xs text-gray-500">{label}</p>
            <p className="text-sm font-medium text-gray-200 mt-0.5 truncate">{value}</p>
          </div>
        ))}
      </div>

      {/* Tabs */}
      <div className="flex gap-1 border-b border-gray-800 pb-0">
        {[
          { key: 'builds',      label: `Builds (${builds.length})` },
          { key: 'jenkinsfile', label: 'Jenkinsfile' },
        ].map(t => (
          <button
            key={t.key}
            onClick={() => { setTab(t.key); if (t.key === 'jenkinsfile') loadJenkinsfile(); }}
            className={`px-4 py-2 text-sm font-medium border-b-2 transition-colors -mb-px ${
              tab === t.key
                ? 'border-brand-500 text-brand-400'
                : 'border-transparent text-gray-500 hover:text-gray-300'
            }`}
          >
            {t.label}
          </button>
        ))}
      </div>

      {/* Tab content */}
      {tab === 'builds' && (
        <div className="space-y-2">
          {builds.length === 0 ? (
            <p className="text-gray-500 text-sm">No builds yet. Click "Sync Jenkins" first, then "Run Build" or push to your repo.</p>
          ) : builds.map(b => (
            <Link key={b.id} to={`/projects/${id}/builds/${b.id}`}
              className="card hover:border-gray-700 transition-colors flex items-center gap-4">
              <div className="font-mono text-xs text-gray-500 w-8">#{b.jenkinsBuildNumber || '–'}</div>
              <span className={STATUS_BADGE[b.status] || 'badge-queued'}>{b.status}</span>
              <div className="flex-1 min-w-0">
                <p className="text-sm text-gray-300 truncate">{b.commitMessage || 'Manual trigger'}</p>
                <p className="text-xs text-gray-600">{b.commitSha?.slice(0, 7)} · by {b.triggeredBy || 'unknown'}</p>
              </div>
              {b.duration && <span className="text-xs text-gray-600">{b.duration}s</span>}
              <span className="text-xs text-gray-600">{formatDistanceToNow(new Date(b.createdAt), { addSuffix: true })}</span>
            </Link>
          ))}
        </div>
      )}

      {tab === 'jenkinsfile' && (
        <div className="card">
          <div className="flex items-center gap-2 mb-3">
            <CodeBracketIcon className="w-4 h-4 text-gray-400" />
            <span className="text-sm font-medium text-gray-300">Generated Jenkinsfile</span>
          </div>
          <pre className="text-xs text-gray-300 bg-gray-950 p-4 rounded-lg overflow-x-auto leading-relaxed max-h-[600px] overflow-y-auto">
            {jenkinsfile || 'Loading…'}
          </pre>
        </div>
      )}
    </div>
  );
}
EOF
echo "  ✔ frontend/src/pages/ProjectDetail.jsx"

echo ""
echo "✅ Files updated! Restart backend to pick up the new endpoint:"
echo ""
echo "  docker compose restart backend"
echo ""
echo "Then in the UI: open any project → click 'Sync Jenkins' → then 'Run Build'"
echo ""
echo "OR sync all projects at once via API:"
echo "  TOKEN=\$(cat /tmp/devopsunify_token 2>/dev/null || echo 'paste-your-jwt-here')"
echo "  for ID in \$(curl -s -H \"Authorization: Bearer \$TOKEN\" http://localhost:3000/api/pipelines/projects | python3 -c \"import sys,json; [print(p['id']) for p in json.load(sys.stdin)]\"); do"
echo "    echo \"Syncing project \$ID...\""
echo "    curl -s -X POST -H \"Authorization: Bearer \$TOKEN\" http://localhost:3000/api/pipelines/projects/\$ID/sync-jenkins"
echo "    echo"
echo "  done"
