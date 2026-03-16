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

    // 1. Analyse repo
    const analysis = await repoAnalyser.analyse(repoUrl, req.user.accessToken, branch);
    const projectName = (name || repoUrl.split('/').pop().replace('.git', '')).toLowerCase().replace(/[^a-z0-9-]/g, '-');
    const repoFullName = repoUrl.replace('https://github.com/', '').replace('.git', '');
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

    // Trigger Jenkins
    const { queueUrl } = await jenkinsService.triggerBuild(project.name);

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
