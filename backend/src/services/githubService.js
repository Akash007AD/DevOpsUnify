const { Octokit } = require('@octokit/rest');
const crypto = require('crypto');
const logger = require('../utils/logger');

class GitHubService {
  _octokit(token) {
    return new Octokit({ auth: token });
  }

  // ── OAuth exchange ─────────────────────────────────────────────────────────
  async exchangeCode(code) {
    const resp = await fetch('https://github.com/login/oauth/access_token', {
      method: 'POST',
      headers: { Accept: 'application/json', 'Content-Type': 'application/json' },
      body: JSON.stringify({
        client_id:     process.env.GITHUB_CLIENT_ID,
        client_secret: process.env.GITHUB_CLIENT_SECRET,
        code,
      }),
    });
    const data = await resp.json();
    if (data.error) throw new Error(`GitHub OAuth error: ${data.error_description}`);
    return data.access_token;
  }

  // ── Get authenticated user ─────────────────────────────────────────────────
  async getUser(token) {
    const octokit = this._octokit(token);
    const { data } = await octokit.users.getAuthenticated();
    return data;
  }

  // ── List repositories ──────────────────────────────────────────────────────
  async listRepos(token) {
    const octokit = this._octokit(token);
    const { data } = await octokit.repos.listForAuthenticatedUser({
      sort: 'updated',
      per_page: 100,
      type: 'all',
    });
    return data.map(r => ({
      id:          r.id,
      name:        r.name,
      fullName:    r.full_name,
      description: r.description,
      private:     r.private,
      url:         r.html_url,
      cloneUrl:    r.clone_url,
      defaultBranch: r.default_branch,
      language:    r.language,
      updatedAt:   r.updated_at,
    }));
  }

  // ── Register webhook on a repo ─────────────────────────────────────────────
  async registerWebhook(token, owner, repo) {
    const octokit = this._octokit(token);
    const webhookUrl = `${process.env.BACKEND_URL || 'http://your-server'}/api/webhooks/github`;
    const secret = process.env.GITHUB_WEBHOOK_SECRET;

    try {
      const { data } = await octokit.repos.createWebhook({
        owner,
        repo,
        config: { url: webhookUrl, content_type: 'json', secret, insecure_ssl: '0' },
        events: ['push', 'pull_request'],
        active: true,
      });
      logger.info(`Webhook created on ${owner}/${repo}: ${data.id}`);
      return data;
    } catch (err) {
      if (err.status === 422) {
        logger.warn(`Webhook already exists on ${owner}/${repo}`);
        return null;
      }
      throw err;
    }
  }

  // ── Verify webhook signature ───────────────────────────────────────────────
  verifyWebhookSignature(rawBody, signatureHeader) {
    const secret = process.env.GITHUB_WEBHOOK_SECRET;
    const expected = `sha256=${crypto
      .createHmac('sha256', secret)
      .update(rawBody)
      .digest('hex')}`;
    return crypto.timingSafeEqual(Buffer.from(expected), Buffer.from(signatureHeader));
  }

  // ── Get repo branches ──────────────────────────────────────────────────────
  async getBranches(token, owner, repo) {
    const octokit = this._octokit(token);
    const { data } = await octokit.repos.listBranches({ owner, repo });
    return data.map(b => b.name);
  }
}

module.exports = new GitHubService();
