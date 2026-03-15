const { DataTypes } = require('sequelize');
const { sequelize } = require('../config/database');

// ── User ───────────────────────────────────────────────────────────────────
const User = sequelize.define('User', {
  id: { type: DataTypes.UUID, defaultValue: DataTypes.UUIDV4, primaryKey: true },
  githubId: { type: DataTypes.STRING, unique: true, allowNull: false },
  login: { type: DataTypes.STRING, allowNull: false },
  name: DataTypes.STRING,
  email: DataTypes.STRING,
  avatarUrl: DataTypes.STRING,
  accessToken: { type: DataTypes.TEXT, allowNull: false },
  role: { type: DataTypes.ENUM('admin', 'developer'), defaultValue: 'developer' },
});

// ── Project ────────────────────────────────────────────────────────────────
const Project = sequelize.define('Project', {
  id: { type: DataTypes.UUID, defaultValue: DataTypes.UUIDV4, primaryKey: true },
  userId: { type: DataTypes.UUID, allowNull: false },
  name: { type: DataTypes.STRING, allowNull: false },
  repoUrl: { type: DataTypes.STRING, allowNull: false },
  repoFullName: DataTypes.STRING,       // owner/repo
  branch: { type: DataTypes.STRING, defaultValue: 'main' },
  projectType: DataTypes.STRING,        // nodejs | python | java | golang | static
  port: { type: DataTypes.INTEGER, defaultValue: 3000 },
  ecrRepo: DataTypes.STRING,
  helmReleaseName: DataTypes.STRING,
  k8sNamespace: { type: DataTypes.STRING, defaultValue: 'default' },
  sonarProjectKey: DataTypes.STRING,
  grafanaDashboardUid: DataTypes.STRING,
  tfWorkspace: DataTypes.STRING,
  status: {
    type: DataTypes.ENUM('pending', 'provisioning', 'active', 'failed'),
    defaultValue: 'pending',
  },
  config: { type: DataTypes.JSONB, defaultValue: {} },
});

// ── Build ──────────────────────────────────────────────────────────────────
const Build = sequelize.define('Build', {
  id: { type: DataTypes.UUID, defaultValue: DataTypes.UUIDV4, primaryKey: true },
  projectId: { type: DataTypes.UUID, allowNull: false },
  jenkinsBuildNumber: DataTypes.INTEGER,
  jenkinsBuildUrl: DataTypes.STRING,
  commitSha: DataTypes.STRING,
  commitMessage: DataTypes.TEXT,
  triggeredBy: DataTypes.STRING,
  status: {
    type: DataTypes.ENUM('queued', 'running', 'success', 'failure', 'aborted'),
    defaultValue: 'queued',
  },
  sonarStatus: DataTypes.STRING,
  trivyStatus: DataTypes.STRING,
  imageTag: DataTypes.STRING,
  duration: DataTypes.INTEGER,    // seconds
  logs: { type: DataTypes.TEXT, defaultValue: '' },
  startedAt: DataTypes.DATE,
  finishedAt: DataTypes.DATE,
});

// ── Infrastructure ─────────────────────────────────────────────────────────
const Infrastructure = sequelize.define('Infrastructure', {
  id: { type: DataTypes.UUID, defaultValue: DataTypes.UUIDV4, primaryKey: true },
  projectId: { type: DataTypes.UUID, allowNull: false },
  type: DataTypes.STRING,             // eks | ecr | rds | vpc
  tfState: DataTypes.TEXT,
  outputs: { type: DataTypes.JSONB, defaultValue: {} },
  status: {
    type: DataTypes.ENUM('pending', 'applying', 'applied', 'destroying', 'destroyed', 'failed'),
    defaultValue: 'pending',
  },
});

// ── Associations ───────────────────────────────────────────────────────────
User.hasMany(Project, { foreignKey: 'userId' });
Project.belongsTo(User, { foreignKey: 'userId' });
Project.hasMany(Build, { foreignKey: 'projectId' });
Build.belongsTo(Project, { foreignKey: 'projectId' });
Project.hasMany(Infrastructure, { foreignKey: 'projectId' });
Infrastructure.belongsTo(Project, { foreignKey: 'projectId' });

module.exports = { User, Project, Build, Infrastructure };
