/**
 * RepoAnalyserService
 *
 * Clones (shallow) the repository and inspects its file tree to determine:
 *  - projectType: nodejs | python | java | golang | static | unknown
 *  - port: detected or default
 *  - buildTool: npm | maven | gradle | pip | go
 *  - hasDockerfile: boolean
 *  - detectedFiles: array of key files found
 */

const fs = require('fs');
const path = require('path');
const simpleGit = require('simple-git');
const os = require('os');
const { v4: uuidv4 } = require('uuid');
const logger = require('../utils/logger');

const SIGNATURES = {
  nodejs:  ['package.json'],
  python:  ['requirements.txt', 'Pipfile', 'pyproject.toml', 'setup.py'],
  java:    ['pom.xml', 'build.gradle', 'build.gradle.kts'],
  golang:  ['go.mod'],
  static:  ['index.html'],
};

const BUILD_TOOLS = {
  'package.json':   'npm',
  'pom.xml':        'maven',
  'build.gradle':   'gradle',
  'requirements.txt': 'pip',
  'Pipfile':        'pipenv',
  'go.mod':         'go',
};

const DEFAULT_PORTS = {
  nodejs: 3000,
  python: 8000,
  java:   8080,
  golang: 8080,
  static: 80,
};

class RepoAnalyserService {
  /**
   * @param {string} repoUrl  - HTTPS URL of the GitHub repo
   * @param {string} token    - GitHub personal access token
   * @param {string} branch   - Branch to analyse (default: main)
   */
  async analyse(repoUrl, token, branch = 'main') {
    const tmpDir = path.join(os.tmpdir(), `devopsunify-${uuidv4()}`);
    try {
      logger.info(`Cloning ${repoUrl} (branch: ${branch}) to ${tmpDir}`);

      const authUrl = this._injectToken(repoUrl, token);
      const git = simpleGit();
      await git.clone(authUrl, tmpDir, ['--depth', '1', '--branch', branch]);

      const files = this._listFiles(tmpDir, 3); // depth 3
      logger.debug(`Found ${files.length} files`);

      const projectType = this._detectType(files);
      const buildTool   = this._detectBuildTool(files);
      const port        = this._detectPort(tmpDir, projectType);
      const hasDockerfile = files.some(f => path.basename(f) === 'Dockerfile');
      const dockerCompose = files.some(f => f.includes('docker-compose'));

      return {
        projectType,
        buildTool,
        port,
        hasDockerfile,
        dockerCompose,
        detectedFiles: files.map(f => path.relative(tmpDir, f)),
        branch,
      };
    } finally {
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  }

  _injectToken(url, token) {
    // https://github.com/org/repo  →  https://token@github.com/org/repo
    return url.replace('https://', `https://${token}@`);
  }

  _listFiles(dir, maxDepth, currentDepth = 0) {
    if (currentDepth > maxDepth) return [];
    const entries = fs.readdirSync(dir, { withFileTypes: true });
    const results = [];
    for (const entry of entries) {
      if (entry.name === '.git') continue;
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        results.push(...this._listFiles(full, maxDepth, currentDepth + 1));
      } else {
        results.push(full);
      }
    }
    return results;
  }

  _detectType(files) {
    const basenames = files.map(f => path.basename(f));
    for (const [type, sigs] of Object.entries(SIGNATURES)) {
      if (sigs.some(s => basenames.includes(s))) return type;
    }
    return 'unknown';
  }

  _detectBuildTool(files) {
    const basenames = files.map(f => path.basename(f));
    for (const [file, tool] of Object.entries(BUILD_TOOLS)) {
      if (basenames.includes(file)) return tool;
    }
    return 'unknown';
  }

  _detectPort(dir, projectType) {
    // Try to read port from package.json scripts or common env files
    try {
      if (projectType === 'nodejs') {
        const pkg = JSON.parse(fs.readFileSync(path.join(dir, 'package.json'), 'utf8'));
        const startScript = pkg.scripts?.start || '';
        const match = startScript.match(/PORT[=\s]+(\d{4,5})/);
        if (match) return parseInt(match[1]);
      }
    } catch (_) { /* ignore */ }
    return DEFAULT_PORTS[projectType] || 3000;
  }
}

module.exports = new RepoAnalyserService();
