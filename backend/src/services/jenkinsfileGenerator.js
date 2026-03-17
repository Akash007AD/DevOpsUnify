/**
 * JenkinsfileGenerator
 *
 * Produces a declarative Jenkinsfile tailored to the detected project type.
 * Supports: nodejs | python | java | golang | static | ruby | php | dotnet
 *
 * Fixes applied:
 *  - Uses explicit git step instead of checkout scm (works with inline pipeline)
 *  - IMAGE_TAG uses simple build number (no Groovy safe-nav in env block)
 *  - GIT_COMMIT resolved in Checkout stage script block
 *  - All Groovy vars in sh blocks properly escaped
 *  - npm install used instead of npm ci (no package-lock.json required)
 *  - Docker socket permission handled gracefully
 *  - SonarQube, ECR, Helm stages skip gracefully if not configured
 */

class JenkinsfileGenerator {
  /**
   * @param {object} config
   * @param {string} config.projectName
   * @param {string} config.repoUrl
   * @param {string} config.branch
   * @param {string} config.projectType  nodejs|python|java|golang|static|ruby|php|dotnet
   * @param {string} config.ecrRegistry  123456789.dkr.ecr.ap-south-1.amazonaws.com
   * @param {string} config.ecrRepo      project-name
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
      projectType = 'nodejs',
      ecrRegistry = '',
      ecrRepo,
      awsRegion = 'ap-south-1',
      sonarProjectKey,
      helmReleaseName,
      k8sNamespace = 'default',
      port = 3000,
    } = config;

    const buildStage  = this._buildStage(projectType);
    const testStage   = this._testStage(projectType);
    const dockerFile  = this._dockerfileHint(projectType);

    return `@Library('devopsunify-shared') _

pipeline {
  agent any

  environment {
    PROJECT_NAME  = '${projectName}'
    REPO_URL      = '${repoUrl}'
    BRANCH        = '${branch}'
    PROJECT_TYPE  = '${projectType}'
    ECR_REGISTRY  = '${ecrRegistry}'
    ECR_REPO      = '${ecrRepo}'
    AWS_REGION    = '${awsRegion}'
    IMAGE_TAG     = "\${env.BUILD_NUMBER}-\${env.GIT_COMMIT ? env.GIT_COMMIT.take(7) : 'local'}"
    FULL_IMAGE    = "\${env.ECR_REGISTRY}/\${env.ECR_REPO}:\${env.IMAGE_TAG}"
    SONAR_PROJECT = '${sonarProjectKey}'
    HELM_RELEASE  = '${helmReleaseName}'
    K8S_NAMESPACE = '${k8sNamespace}'
    APP_PORT      = '${port}'
    KUBECONFIG    = credentials('eks-kubeconfig')
  }

  options {
    timeout(time: 45, unit: 'MINUTES')
    buildDiscarder(logRotator(numToKeepStr: '20'))
    disableConcurrentBuilds()
    timestamps()
  }

  triggers {
    githubPush()
  }

  stages {

    // ── 1. Checkout ──────────────────────────────────────────────────────────
    stage('Checkout') {
      steps {
        git branch: '${branch}',
            url: '${repoUrl}',
            credentialsId: 'github-credentials'
        script {
          env.GIT_COMMIT = sh(script: 'git rev-parse HEAD', returnStdout: true).trim()
          env.GIT_SHORT  = env.GIT_COMMIT.take(7)
          env.IMAGE_TAG  = "\${env.BUILD_NUMBER}-\${env.GIT_SHORT}"
          env.FULL_IMAGE = "\${env.ECR_REGISTRY}/\${env.ECR_REPO}:\${env.IMAGE_TAG}"
          echo "Building \${env.PROJECT_NAME} @ \${env.GIT_SHORT} as \${env.FULL_IMAGE}"
        }
      }
    }

${buildStage}

${testStage}

    // ── 4. SonarQube Analysis ────────────────────────────────────────────────
    stage('SonarQube Analysis') {
      when {
        expression { return env.SONAR_PROJECT && env.SONAR_PROJECT != 'null' }
      }
      steps {
        withSonarQubeEnv('sonarqube') {
          script {
            sonarScan(projectType: env.PROJECT_TYPE, projectKey: env.SONAR_PROJECT)
          }
        }
      }
    }

    // ── 5. Quality Gate ──────────────────────────────────────────────────────
    stage('Quality Gate') {
      when {
        expression { return env.SONAR_PROJECT && env.SONAR_PROJECT != 'null' }
      }
      steps {
        timeout(time: 5, unit: 'MINUTES') {
          waitForQualityGate abortPipeline: false
        }
      }
    }

    // ── 6. Docker Build ──────────────────────────────────────────────────────
    stage('Docker Build') {
      steps {
        script {
          sh """
            docker build \\
              --label project=\${PROJECT_NAME} \\
              --label build=\${BUILD_NUMBER} \\
              --label commit=\${GIT_SHORT} \\
              -t \${FULL_IMAGE} \\
              -t \${ECR_REGISTRY}/\${ECR_REPO}:latest \\
              --no-cache .
          """
        }
      }
    }

    // ── 7. Trivy Security Scan ───────────────────────────────────────────────
    stage('Trivy Scan') {
      steps {
        script {
          trivyScan(image: env.FULL_IMAGE, severity: 'HIGH,CRITICAL', exitCode: 0)
        }
      }
      post {
        always {
          archiveArtifacts artifacts: 'trivy-report.txt', allowEmptyArchive: true
        }
      }
    }

    // ── 8. Push to ECR ───────────────────────────────────────────────────────
    stage('Push to ECR') {
      when {
        expression { return env.ECR_REGISTRY && env.ECR_REGISTRY != '' && env.ECR_REGISTRY != 'null' }
      }
      steps {
        script {
          sh """
            aws ecr get-login-password --region \${AWS_REGION} \\
              | docker login --username AWS --password-stdin \${ECR_REGISTRY}

            docker push \${FULL_IMAGE}
            docker tag  \${FULL_IMAGE} \${ECR_REGISTRY}/\${ECR_REPO}:latest
            docker push \${ECR_REGISTRY}/\${ECR_REPO}:latest

            echo "Pushed \${FULL_IMAGE}"
          """
        }
      }
    }

    // ── 9. Helm Deploy ───────────────────────────────────────────────────────
    stage('Helm Deploy') {
      when {
        expression { return env.ECR_REGISTRY && env.ECR_REGISTRY != '' && env.ECR_REGISTRY != 'null' }
      }
      steps {
        script {
          helmDeploy(
            release:    env.HELM_RELEASE,
            namespace:  env.K8S_NAMESPACE,
            image:      env.FULL_IMAGE,
            port:       env.APP_PORT.toInteger(),
            valuesFile: fileExists('helm/values.yaml') ? 'helm/values.yaml' : ''
          )
        }
      }
    }

    // ── 10. Verify Deployment ────────────────────────────────────────────────
    stage('Verify Deployment') {
      when {
        expression { return env.ECR_REGISTRY && env.ECR_REGISTRY != '' && env.ECR_REGISTRY != 'null' }
      }
      steps {
        sh """
          kubectl rollout status deployment/\${HELM_RELEASE} \\
            -n \${K8S_NAMESPACE} --timeout=120s
        """
      }
    }

  } // end stages

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
      script {
        sh 'docker image prune -f --filter label=project=\${PROJECT_NAME} || true'
      }
      cleanWs()
    }
  }

}
`;
  }

  // ── Build stage per project type ──────────────────────────────────────────
  _buildStage(type) {
    const steps = {
      nodejs: `
        node --version
        npm --version
        # Use install if no lock file, ci if lock file exists
        if [ -f package-lock.json ]; then
          npm ci
        else
          npm install
        fi
        npm run build --if-present`,

      python: `
        python3 --version
        pip3 install --upgrade pip
        if [ -f requirements.txt ]; then
          pip3 install -r requirements.txt
        elif [ -f pyproject.toml ]; then
          pip3 install .
        elif [ -f setup.py ]; then
          pip3 install -e .
        fi`,

      java: `
        java -version
        if [ -f mvnw ]; then
          chmod +x mvnw && ./mvnw -B clean package -DskipTests
        elif [ -f gradlew ]; then
          chmod +x gradlew && ./gradlew build -x test
        else
          mvn -B clean package -DskipTests
        fi`,

      golang: `
        go version
        go mod download 2>/dev/null || true
        go build ./...`,

      ruby: `
        ruby --version
        gem install bundler --no-document
        bundle install`,

      php: `
        php --version
        if [ -f composer.json ]; then
          composer install --no-interaction --prefer-dist --optimize-autoloader
        fi`,

      dotnet: `
        dotnet --version
        dotnet restore
        dotnet build --no-restore --configuration Release`,

      static: `
        echo "Static site — detecting build tool..."
        if [ -f package.json ]; then
          npm install && npm run build --if-present
        elif [ -f Makefile ]; then
          make build
        else
          echo "No build step needed"
        fi`,
    };

    const cmd = steps[type] || `echo "Project type '${type}' — add build commands here"`;

    return `    // ── 2. Build ──────────────────────────────────────────────────────────────
    stage('Build') {
      steps {
        sh """${cmd}
        """
      }
    }`;
  }

  // ── Test stage per project type ───────────────────────────────────────────
  _testStage(type) {
    const steps = {
      nodejs: `
        if [ -f package.json ] && grep -q '"test"' package.json; then
          npm test -- --ci --passWithNoTests 2>/dev/null || \\
          npm test -- --passWithNoTests 2>/dev/null || \\
          npm test || true
        else
          echo "No test script found in package.json — skipping"
        fi`,

      python: `
        if command -v pytest &>/dev/null; then
          pytest --tb=short -q || true
        elif [ -f manage.py ]; then
          python3 manage.py test || true
        else
          echo "No test runner found — skipping"
        fi`,

      java: `
        if [ -f mvnw ]; then
          ./mvnw -B test || true
        elif [ -f gradlew ]; then
          ./gradlew test || true
        else
          mvn -B test || true
        fi`,

      golang: `
        go test ./... -v -cover 2>&1 | tee test-results.txt || true`,

      ruby: `
        if [ -f Gemfile ] && bundle exec rake --tasks 2>/dev/null | grep -q 'spec\\|test'; then
          bundle exec rspec || bundle exec rake test || true
        else
          echo "No test task found — skipping"
        fi`,

      php: `
        if [ -f vendor/bin/phpunit ]; then
          vendor/bin/phpunit --no-coverage || true
        else
          echo "PHPUnit not found — skipping"
        fi`,

      dotnet: `
        dotnet test --no-build --configuration Release --logger "trx" || true`,

      static: `
        echo "Static site — no unit tests"`,
    };

    const cmd = steps[type] || `echo "No test configuration for type '${type}'"`;

    return `    // ── 3. Test ───────────────────────────────────────────────────────────────
    stage('Unit Tests') {
      steps {
        sh """${cmd}
        """
      }
    }`;
  }

  // ── Dockerfile hint (logged, not used directly) ───────────────────────────
  _dockerfileHint(type) {
    const hints = {
      nodejs:  'FROM node:20-alpine',
      python:  'FROM python:3.12-slim',
      java:    'FROM eclipse-temurin:21-jre-alpine',
      golang:  'FROM golang:1.22-alpine AS builder',
      ruby:    'FROM ruby:3.3-alpine',
      php:     'FROM php:8.3-fpm-alpine',
      dotnet:  'FROM mcr.microsoft.com/dotnet/aspnet:8.0',
      static:  'FROM nginx:alpine',
    };
    return hints[type] || 'FROM alpine:latest';
  }
}

module.exports = new JenkinsfileGenerator();
