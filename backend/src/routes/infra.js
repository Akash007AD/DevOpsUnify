const router = require('express').Router();
const { authenticate } = require('../middleware/auth');
const { Project, Infrastructure } = require('../models');
const terraformService = require('../services/terraformService');
const { emitBuildLog } = require('../config/socket');
const logger = require('../utils/logger');

// Provision infrastructure for a project
router.post('/projects/:id/provision', authenticate, async (req, res, next) => {
  try {
    const project = await Project.findOne({ where: { id: req.params.id, userId: req.user.id } });
    if (!project) return res.status(404).json({ error: 'Project not found' });

    const infra = await Infrastructure.create({
      projectId: project.id,
      type: 'full-stack',
      status: 'applying',
    });

    res.status(202).json({ infra, message: 'Provisioning started' });

    // Async provisioning
    _runProvision(project, infra).catch(e => logger.error('Provision error:', e));
  } catch (err) { next(err); }
});

// Get infrastructure status
router.get('/projects/:id/infra', authenticate, async (req, res, next) => {
  try {
    const infras = await Infrastructure.findAll({ where: { projectId: req.params.id } });
    res.json(infras);
  } catch (err) { next(err); }
});

// Destroy infrastructure
router.delete('/projects/:id/infra', authenticate, async (req, res, next) => {
  try {
    const project = await Project.findOne({ where: { id: req.params.id, userId: req.user.id } });
    if (!project) return res.status(404).json({ error: 'Project not found' });

    const infra = await Infrastructure.findOne({ where: { projectId: project.id } });
    if (!infra) return res.status(404).json({ error: 'No infrastructure found' });

    await infra.update({ status: 'destroying' });
    res.json({ message: 'Destroy started' });

    _runDestroy(project, infra).catch(e => logger.error('Destroy error:', e));
  } catch (err) { next(err); }
});

async function _runProvision(project, infra) {
  try {
    const outputs = await terraformService.provision({
      projectId:   project.id,
      projectName: project.name,
      awsRegion:   process.env.AWS_REGION || 'ap-south-1',
      environment: 'dev',
      onLog: (line) => emitBuildLog(`infra-${project.id}`, line),
    });

    await infra.update({ status: 'applied', outputs });
    await project.update({
      ecrRepo:      outputs.ecr_repository_url?.split('/').pop() || project.name,
      tfWorkspace:  project.id,
    });
  } catch (err) {
    await infra.update({ status: 'failed' });
    logger.error('Terraform provision failed:', err);
  }
}

async function _runDestroy(project, infra) {
  try {
    await terraformService.destroy({
      projectId:   project.id,
      projectName: project.name,
      awsRegion:   process.env.AWS_REGION || 'ap-south-1',
      environment: 'dev',
      onLog: (line) => emitBuildLog(`infra-${project.id}`, line),
    });
    await infra.update({ status: 'destroyed' });
  } catch (err) {
    await infra.update({ status: 'failed' });
    logger.error('Terraform destroy failed:', err);
  }
}

module.exports = router;
