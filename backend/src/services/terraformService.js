const { exec } = require('child_process');
const fs = require('fs');
const path = require('path');
const os = require('os');
const { promisify } = require('util');
const { v4: uuidv4 } = require('uuid');
const logger = require('../utils/logger');
const { emitBuildLog } = require('../config/socket');

const execAsync = promisify(exec);

const TF_MODULES_DIR = path.join(__dirname, '../../..', 'terraform');

class TerraformService {
  /**
   * Provision full infrastructure for a project.
   * Runs: init → workspace select/new → apply
   *
   * @param {object} opts
   * @param {string} opts.projectId
   * @param {string} opts.projectName
   * @param {string} opts.awsRegion
   * @param {string} opts.environment  dev | prod
   * @param {function} opts.onLog      callback(line)
   */
  async provision({ projectId, projectName, awsRegion, environment = 'dev', onLog = () => {} }) {
    const workDir = path.join(TF_MODULES_DIR, 'environments', environment);
    const varFile = await this._writeTfVars(projectName, awsRegion, projectId);

    try {
      await this._run('terraform init -reconfigure', workDir, onLog);
      await this._run(`terraform workspace new ${projectId} || terraform workspace select ${projectId}`, workDir, onLog);
      await this._run(`terraform apply -auto-approve -var-file="${varFile}"`, workDir, onLog);
      const outputs = await this._getOutputs(workDir);
      return outputs;
    } finally {
      fs.unlinkSync(varFile);
    }
  }

  async destroy({ projectId, projectName, awsRegion, environment = 'dev', onLog = () => {} }) {
    const workDir = path.join(TF_MODULES_DIR, 'environments', environment);
    const varFile = await this._writeTfVars(projectName, awsRegion, projectId);

    try {
      await this._run(`terraform workspace select ${projectId}`, workDir, onLog);
      await this._run(`terraform destroy -auto-approve -var-file="${varFile}"`, workDir, onLog);
      await this._run(`terraform workspace select default`, workDir, onLog);
      await this._run(`terraform workspace delete ${projectId}`, workDir, onLog);
    } finally {
      fs.unlinkSync(varFile);
    }
  }

  async _getOutputs(workDir) {
    const { stdout } = await execAsync('terraform output -json', { cwd: workDir });
    const raw = JSON.parse(stdout);
    const out = {};
    for (const [k, v] of Object.entries(raw)) {
      out[k] = v.value;
    }
    return out;
  }

  async _writeTfVars(projectName, awsRegion, projectId) {
    const tmpFile = path.join(os.tmpdir(), `tfvars-${uuidv4()}.tfvars`);
    const content = `
project_name = "${projectName}"
aws_region   = "${awsRegion}"
project_id   = "${projectId}"
    `.trim();
    fs.writeFileSync(tmpFile, content);
    return tmpFile;
  }

  async _run(cmd, cwd, onLog) {
    return new Promise((resolve, reject) => {
      logger.info(`TF> ${cmd}`);
      const child = exec(cmd, {
        cwd,
        env: {
          ...process.env,
          TF_IN_AUTOMATION: '1',
          TF_CLI_ARGS: '-no-color',
        },
      });

      child.stdout.on('data', (d) => {
        const line = d.toString().trim();
        logger.debug(line);
        onLog(line);
      });
      child.stderr.on('data', (d) => {
        const line = d.toString().trim();
        logger.warn(line);
        onLog(line);
      });
      child.on('close', (code) => {
        if (code !== 0) return reject(new Error(`Terraform exited with code ${code}`));
        resolve();
      });
    });
  }
}

module.exports = new TerraformService();
