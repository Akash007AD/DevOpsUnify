const router = require('express').Router();
const { authenticate } = require('../middleware/auth');
const githubService = require('../services/githubService');
const repoAnalyser = require('../services/repoAnalyser');

// List GitHub repos for authenticated user
router.get('/', authenticate, async (req, res, next) => {
  try {
    const repos = await githubService.listRepos(req.user.accessToken);
    res.json(repos);
  } catch (err) { next(err); }
});

// Analyse a specific repo
router.post('/analyse', authenticate, async (req, res, next) => {
  try {
    const { repoUrl, branch = 'main' } = req.body;
    if (!repoUrl) return res.status(400).json({ error: 'repoUrl required' });

    const result = await repoAnalyser.analyse(repoUrl, req.user.accessToken, branch);
    res.json(result);
  } catch (err) { next(err); }
});

// Get branches for a repo
router.get('/:owner/:repo/branches', authenticate, async (req, res, next) => {
  try {
    const branches = await githubService.getBranches(
      req.user.accessToken,
      req.params.owner,
      req.params.repo
    );
    res.json(branches);
  } catch (err) { next(err); }
});

module.exports = router;
