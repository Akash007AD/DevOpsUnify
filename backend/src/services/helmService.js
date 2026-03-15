const fs = require('fs');
const path = require('path');
const yaml = require('yaml');
const logger = require('../utils/logger');

class HelmService {
  /**
   * Generate a values.yaml for the platform's webapp Helm chart
   */
  generateValues({ projectName, image, tag, port, replicas = 2, namespace, ecrRegistry, ecrRepo }) {
    const values = {
      replicaCount: replicas,
      image: {
        repository: `${ecrRegistry}/${ecrRepo}`,
        tag: tag || 'latest',
        pullPolicy: 'Always',
      },
      service: {
        type: 'ClusterIP',
        port: 80,
        targetPort: port,
      },
      ingress: {
        enabled: true,
        className: 'nginx',
        annotations: {
          'nginx.ingress.kubernetes.io/rewrite-target': '/',
        },
        hosts: [
          {
            host: `${projectName}.devopsunify.internal`,
            paths: [{ path: '/', pathType: 'Prefix' }],
          },
        ],
      },
      resources: {
        requests: { cpu: '100m', memory: '128Mi' },
        limits:   { cpu: '500m', memory: '512Mi' },
      },
      autoscaling: {
        enabled: true,
        minReplicas: 2,
        maxReplicas: 10,
        targetCPUUtilizationPercentage: 70,
      },
      serviceAccount: {
        create: true,
        name: projectName,
      },
      podAnnotations: {
        'prometheus.io/scrape': 'true',
        'prometheus.io/port':   String(port),
        'prometheus.io/path':   '/metrics',
      },
      env: [],
      livenessProbe: {
        httpGet: { path: '/health', port },
        initialDelaySeconds: 15,
        periodSeconds: 20,
      },
      readinessProbe: {
        httpGet: { path: '/health', port },
        initialDelaySeconds: 5,
        periodSeconds: 10,
      },
    };

    return yaml.stringify(values);
  }

  /**
   * Write values.yaml to the project repo directory
   */
  writeValuesFile(destDir, values) {
    const helmDir = path.join(destDir, 'helm');
    fs.mkdirSync(helmDir, { recursive: true });
    const filePath = path.join(helmDir, 'values.yaml');
    fs.writeFileSync(filePath, values);
    logger.info(`Helm values written to ${filePath}`);
    return filePath;
  }
}

module.exports = new HelmService();
