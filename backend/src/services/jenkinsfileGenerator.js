/**
 * JenkinsfileGenerator
 *
 * Produces a declarative Jenkinsfile tailored to the detected project type.
 * Uses Jenkins Shared Library calls (@Library('devopsunify-shared')) for
 * sonar, trivy, helm, and slack notification steps.
 */

class JenkinsfileGenerator {
  /**
   * @param {object} config
   * @param {string} config.projectName
   * @param {string} config.repoUrl
   * @param {string} config.branch
   * @param {string} config.projectType    nodejs | python | java | golang | static
   * @param {string} config.ecrRegistry    123456789.dkr.ecr.ap-south-1.amazonaws.com
   * @param {string} config.ecrRepo        project-name
   * @param {string} config.awsRegion
   * @param {string} config.sonarProjectKey
   * @param {string} config.helmReleaseName
   * @param {string} config.k8sNamespace
   * @param {number} config.port
   */
  generate(config) {
    const {
      projectName,
      repoUrl,
      branch = 'main',
      projectType,
      ecrRegistry,
      ecrRepo,
      awsRegion = 'ap-south-1',
      sonarProjectKey,
      helmReleaseName,
      k8sNamespace = 'default',
      port = 3000,
    } = config;

    const buildStage   = this._buildStage(projectType);
    const testStage    = this._testStage(projectType);

    return `@Library('devopsunify-shared') _

pipeline {
  agent any

  environment {
    PROJECT_NAME    = '${projectName}'
    ECR_REGISTRY    = '${ecrRegistry}'
    ECR_REPO        = '${ecrRepo}'
    AWS_REGION      = '${awsRegion}'
    IMAGE_TAG       = "\${env.BUILD_NUMBER}-\${env.GIT_COMMIT?.take(7) ?: 'local'}"
    FULL_IMAGE      = "\${ECR_REGISTRY}/\${ECR_REPO}:\${IMAGE_TAG}"
    SONAR_PROJECT   = '${sonarProjectKey}'
    HELM_RELEASE    = '${helmReleaseName}'
    K8S_NAMESPACE   = '${k8sNamespace}'
    KUBECONFIG      = credentials('eks-kubeconfig')
  }

  options {
    timeout(time: 30, unit: 'MINUTES')
    buildDiscarder(logRotator(numToKeepStr: '20'))
    skipStagesAfterUnstable()
  }

  triggers {
    githubPush()
  }

  stages {
    stage('Checkout') {
      steps {
        checkout scm
        script { env.GIT_COMMIT = sh(script: 'git rev-parse HEAD', returnStdout: true).trim() }
      }
    }

${buildStage}

${testStage}

    stage('SonarQube Analysis') {
      steps {
        withSonarQubeEnv('sonarqube') {
          script { sonarScan(projectType: '${projectType}', projectKey: env.SONAR_PROJECT) }
        }
      }
    }

    stage('Quality Gate') {
      steps {
        timeout(time: 5, unit: 'MINUTES') {
          waitForQualityGate abortPipeline: true
        }
      }
    }

    stage('Docker Build') {
      steps {
        script {
          docker.build(env.FULL_IMAGE, '--no-cache .')
        }
      }
    }

    stage('Trivy Image Scan') {
      steps {
        script {
          trivyScan(image: env.FULL_IMAGE, severity: 'HIGH,CRITICAL', exitCode: 1)
        }
      }
      post {
        always {
          archiveArtifacts artifacts: 'trivy-report.txt', allowEmptyArchive: true
        }
      }
    }

    stage('Push to ECR') {
      steps {
        script {
          sh """
            aws ecr get-login-password --region \${AWS_REGION} \\
              | docker login --username AWS --password-stdin \${ECR_REGISTRY}
            docker push \${FULL_IMAGE}
            docker tag \${FULL_IMAGE} \${ECR_REGISTRY}/\${ECR_REPO}:latest
            docker push \${ECR_REGISTRY}/\${ECR_REPO}:latest
          """
        }
      }
    }

    stage('Helm Deploy') {
      steps {
        script {
          helmDeploy(
            release:    env.HELM_RELEASE,
            namespace:  env.K8S_NAMESPACE,
            image:      env.FULL_IMAGE,
            port:       ${port},
            valuesFile: 'helm/values.yaml'
          )
        }
      }
    }

    stage('Verify Deployment') {
      steps {
        sh """
          kubectl rollout status deployment/\${HELM_RELEASE} \\
            -n \${K8S_NAMESPACE} --timeout=120s
        """
      }
    }
  }

  post {
    success {
      script {
        notifySlack(status: 'SUCCESS', buildUrl: env.BUILD_URL, project: env.PROJECT_NAME)
      }
    }
    failure {
      script {
        notifySlack(status: 'FAILURE', buildUrl: env.BUILD_URL, project: env.PROJECT_NAME)
      }
    }
    always {
      cleanWs()
      script {
        sh 'docker image prune -f --filter label=project=\${PROJECT_NAME} || true'
      }
    }
  }
}`;
  }

  _buildStage(type) {
    const cmds = {
      nodejs:  'npm ci\n          npm run build --if-present',
      python:  'pip install -r requirements.txt',
      java:    'mvn -B clean package -DskipTests',
      golang:  'go build ./...',
      static:  'echo "Static site — no build step"',
    };
    return `    stage('Build') {
      steps {
        sh """
          ${cmds[type] || 'echo "Unknown project type"'}
        """
      }
    }`;
  }

  _testStage(type) {
    const cmds = {
      nodejs:  'npm test -- --ci --coverage || true',
      python:  'pytest --tb=short || true',
      java:    'mvn -B test',
      golang:  'go test ./... -v || true',
      static:  'echo "No tests for static site"',
    };
    return `    stage('Unit Tests') {
      steps {
        sh """
          ${cmds[type] || 'echo "No test command configured"'}
        """
      }
    }`;
  }
}

module.exports = new JenkinsfileGenerator();
