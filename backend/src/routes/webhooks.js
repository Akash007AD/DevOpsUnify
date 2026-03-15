const router = require('express').Router();
const githubService = require('../services/githubService');
const jenkinsService = require('../services/jenkinsService');
const { Project, Build } = require('../models');
const { emitBuildStatus } = require('../config/socket');
const logger = require('../utils/logger');

// GitHub sends raw JSON body — we kept it raw in app.js for signature check
router.post('/github', async (req, res) => {
  const sig = req.headers['x-hub-signature-256'];
  if (!sig) return res.status(400).send('Missing signature');

  if (!githubService.verifyWebhookSignature(req.body, sig)) {
    logger.warn('Webhook signature mismatch');
    return res.status(401).send('Invalid signature');
  }

  const event = req.headers['x-github-event'];
  const payload = JSON.parse(req.body.toString());

  res.status(200).send('OK'); // Respond immediately

  if (event === 'push') {
    const repoFullName = payload.repository?.full_name;
    const branch       = payload.ref?.replace('refs/heads/', '');
    const commitSha    = payload.after;
    const commitMsg    = payload.head_commit?.message;
    const pusher       = payload.pusher?.name;

    logger.info(`Push webhook: ${repoFullName} @ ${branch} (${commitSha?.slice(0, 7)})`);

    try {
      const project = await Project.findOne({ where: { repoFullName, branch } });
      if (!project) {
        logger.info(`No project found for ${repoFullName}:${branch} — skipping`);
        return;
      }

      const build = await Build.create({
        projectId:     project.id,
        commitSha,
        commitMessage: commitMsg,
        triggeredBy:   pusher,
        status: 'queued',
      });

      const { queueUrl } = await jenkinsService.triggerBuild(project.name, {
        GIT_COMMIT: commitSha,
        BRANCH:     branch,
      });

      // Resolve build number async
      jenkinsService.getBuildNumberFromQueue(queueUrl).then(num => {
        build.update({ jenkinsBuildNumber: num, status: 'running', startedAt: new Date() });
        emitBuildStatus(build.id, 'running');
      }).catch(e => logger.error('Queue resolve error:', e));

    } catch (err) {
      logger.error('Webhook push handler error:', err);
    }
  }
});

module.exports = router;
