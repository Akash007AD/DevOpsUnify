const axios = require('axios');
const logger = require('../utils/logger');

function grafanaClient() {
  return axios.create({
    baseURL: process.env.GRAFANA_URL,
    headers: {
      Authorization: `Bearer ${process.env.GRAFANA_API_KEY}`,
      'Content-Type': 'application/json',
    },
  });
}

class GrafanaService {
  async createDashboard(projectName, projectType) {
    const client = grafanaClient();
    const dashboard = this._buildDashboard(projectName, projectType);

    const res = await client.post('/api/dashboards/db', {
      dashboard,
      folderId: 0,
      overwrite: true,
    });

    logger.info(`Grafana dashboard created for ${projectName}: uid=${res.data.uid}`);
    return { uid: res.data.uid, url: res.data.url };
  }

  async getDashboardUrl(uid) {
    return `${process.env.GRAFANA_URL}/d/${uid}`;
  }

  _buildDashboard(projectName, projectType) {
    return {
      uid:   `devopsunify-${projectName}`,
      title: `${projectName} — DevOpsUnify`,
      tags:  ['devopsunify', projectType],
      timezone: 'browser',
      refresh: '10s',
      panels: [
        this._cpuPanel(projectName, 1),
        this._memPanel(projectName, 2),
        this._httpRpsPanel(projectName, 3),
        this._httpLatencyPanel(projectName, 4),
        this._podCountPanel(projectName, 5),
      ],
    };
  }

  _cpuPanel(projectName, id) {
    return {
      id, type: 'timeseries',
      title: 'CPU Usage',
      gridPos: { x: 0, y: 0, w: 12, h: 8 },
      targets: [{
        expr: `sum(rate(container_cpu_usage_seconds_total{namespace="default",pod=~"${projectName}-.*"}[5m])) by (pod)`,
        legendFormat: '{{pod}}',
      }],
      fieldConfig: { defaults: { unit: 'percentunit' } },
    };
  }

  _memPanel(projectName, id) {
    return {
      id, type: 'timeseries',
      title: 'Memory Usage',
      gridPos: { x: 12, y: 0, w: 12, h: 8 },
      targets: [{
        expr: `sum(container_memory_working_set_bytes{namespace="default",pod=~"${projectName}-.*"}) by (pod)`,
        legendFormat: '{{pod}}',
      }],
      fieldConfig: { defaults: { unit: 'bytes' } },
    };
  }

  _httpRpsPanel(projectName, id) {
    return {
      id, type: 'timeseries',
      title: 'HTTP Requests/sec',
      gridPos: { x: 0, y: 8, w: 12, h: 8 },
      targets: [{
        expr: `sum(rate(http_requests_total{job="${projectName}"}[1m])) by (status)`,
        legendFormat: '{{status}}',
      }],
    };
  }

  _httpLatencyPanel(projectName, id) {
    return {
      id, type: 'timeseries',
      title: 'P95 Latency',
      gridPos: { x: 12, y: 8, w: 12, h: 8 },
      targets: [{
        expr: `histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket{job="${projectName}"}[5m])) by (le))`,
        legendFormat: 'P95',
      }],
      fieldConfig: { defaults: { unit: 's' } },
    };
  }

  _podCountPanel(projectName, id) {
    return {
      id, type: 'stat',
      title: 'Running Pods',
      gridPos: { x: 0, y: 16, w: 6, h: 4 },
      targets: [{
        expr: `count(kube_pod_info{namespace="default",pod=~"${projectName}-.*"})`,
      }],
    };
  }
}

module.exports = new GrafanaService();
