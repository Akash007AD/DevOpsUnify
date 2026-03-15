const router = require('express').Router();
const jwt = require('jsonwebtoken');
const githubService = require('../services/githubService');
const { User } = require('../models');
const { authenticate } = require('../middleware/auth');

// Step 1: Redirect to GitHub
router.get('/github', (req, res) => {
  const params = new URLSearchParams({
    client_id: process.env.GITHUB_CLIENT_ID,
    redirect_uri: process.env.GITHUB_CALLBACK_URL,
    scope: 'repo,admin:repo_hook,read:user,user:email',
  });
  res.redirect(`https://github.com/login/oauth/authorize?${params}`);
});

// Step 2: GitHub redirects back with ?code=
router.get('/github/callback', async (req, res) => {
  try {
    const { code } = req.query;
    if (!code) return res.status(400).json({ error: 'Missing code' });

    const accessToken = await githubService.exchangeCode(code);
    const ghUser = await githubService.getUser(accessToken);

    let user = await User.findOne({ where: { githubId: String(ghUser.id) } });
    if (!user) {
      user = await User.create({
        githubId:    String(ghUser.id),
        login:       ghUser.login,
        name:        ghUser.name,
        email:       ghUser.email,
        avatarUrl:   ghUser.avatar_url,
        accessToken,
      });
    } else {
      await user.update({ accessToken, name: ghUser.name, avatarUrl: ghUser.avatar_url });
    }

    const token = jwt.sign({ userId: user.id }, process.env.JWT_SECRET, {
      expiresIn: process.env.JWT_EXPIRES_IN || '7d',
    });

    // Redirect to frontend with token
    res.redirect(`${process.env.FRONTEND_URL || 'http://localhost:5173'}/auth/callback?token=${token}`);
  } catch (err) {
    res.redirect(`${process.env.FRONTEND_URL || 'http://localhost:5173'}/auth/error`);
  }
});

// Get current user
router.get('/me', authenticate, (req, res) => {
  const { id, login, name, email, avatarUrl, role } = req.user;
  res.json({ id, login, name, email, avatarUrl, role });
});

module.exports = router;
