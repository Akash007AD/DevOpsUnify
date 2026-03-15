#!/usr/bin/env bash
# =============================================================================
# DevOpsUnify — Jenkins EC2 Setup Script
# Installs Jenkins LTS + all required plugins on Ubuntu 22.04
# Run ONCE on your Jenkins EC2 instance as ubuntu user
# Usage: ./scripts/setup/setup-jenkins.sh
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; exit 1; }

JENKINS_PORT=${JENKINS_PORT:-8080}
JENKINS_HOME=${JENKINS_HOME:-/var/lib/jenkins}

# ===========================================================================
# 1. Install Java 17 (required by Jenkins LTS)
# ===========================================================================
log "Installing Java 17..."
sudo apt-get update -qq
sudo apt-get install -y -qq fontconfig openjdk-17-jre
java -version

# ===========================================================================
# 2. Install Jenkins LTS
# ===========================================================================
log "Installing Jenkins LTS..."
curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key | \
  sudo tee /usr/share/keyrings/jenkins-keyring.asc > /dev/null
echo "deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc] \
  https://pkg.jenkins.io/debian-stable binary/" | \
  sudo tee /etc/apt/sources.list.d/jenkins.list > /dev/null
sudo apt-get update -qq
sudo apt-get install -y -qq jenkins
sudo systemctl enable jenkins
sudo systemctl start jenkins

# Wait for Jenkins to start
log "Waiting for Jenkins to start..."
timeout 120 bash -c 'until curl -s http://localhost:'"$JENKINS_PORT"'/login > /dev/null; do sleep 3; done'
log "Jenkins is up"

# ===========================================================================
# 3. Install Docker (Jenkins needs to run docker commands)
# ===========================================================================
log "Installing Docker..."
curl -fsSL https://get.docker.com | sudo bash
sudo usermod -aG docker jenkins
sudo systemctl restart jenkins

# ===========================================================================
# 4. Install tools Jenkins agents will use
# ===========================================================================
log "Installing kubectl, helm, trivy, sonar-scanner for Jenkins..."

# kubectl
KUBECTL_VERSION=$(curl -fsSL https://dl.k8s.io/release/stable.txt)
sudo curl -fsSLo /usr/local/bin/kubectl \
  "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
sudo chmod +x /usr/local/bin/kubectl

# Helm
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Trivy
curl -fsSL https://aquasecurity.github.io/trivy-repo/deb/public.key | \
  sudo gpg --dearmor -o /usr/share/keyrings/trivy.gpg
echo "deb [signed-by=/usr/share/keyrings/trivy.gpg] \
  https://aquasecurity.github.io/trivy-repo/deb generic main" | \
  sudo tee /etc/apt/sources.list.d/trivy.list
sudo apt-get update -qq && sudo apt-get install -y trivy

# SonarQube Scanner
SONAR_VERSION="5.0.1.3006"
sudo curl -fsSLo /tmp/sonar-scanner.zip \
  "https://binaries.sonarsource.com/Distribution/sonar-scanner-cli/sonar-scanner-cli-${SONAR_VERSION}-linux.zip"
sudo unzip -q /tmp/sonar-scanner.zip -d /opt/
sudo ln -sf "/opt/sonar-scanner-${SONAR_VERSION}-linux/bin/sonar-scanner" /usr/local/bin/sonar-scanner
sudo rm -f /tmp/sonar-scanner.zip

# Node.js (for Node projects)
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt-get install -y nodejs

# ===========================================================================
# 5. Jenkins CLI — install required plugins
# ===========================================================================
log "Installing Jenkins plugins..."
JENKINS_CLI_JAR="/tmp/jenkins-cli.jar"
JENKINS_URL="http://localhost:${JENKINS_PORT}"

# Wait for initial password to be generated
timeout 60 bash -c 'until [ -f /var/lib/jenkins/secrets/initialAdminPassword ]; do sleep 2; done'
ADMIN_PASS=$(sudo cat /var/lib/jenkins/secrets/initialAdminPassword)

# Download CLI jar
curl -fsSLo "$JENKINS_CLI_JAR" "${JENKINS_URL}/jnlpJars/jenkins-cli.jar"

PLUGINS=(
  "git"
  "github"
  "github-branch-source"
  "workflow-aggregator"
  "pipeline-stage-view"
  "blueocean"
  "docker-workflow"
  "docker-plugin"
  "kubernetes"
  "kubernetes-cli"
  "sonar"
  "jacoco"
  "htmlpublisher"
  "slack"
  "credentials"
  "credentials-binding"
  "ssh-credentials"
  "amazon-ecr"
  "aws-credentials"
  "job-dsl"
  "configuration-as-code"
  "ws-cleanup"
  "build-timeout"
  "timestamper"
  "ansicolor"
  "warnings-ng"
)

for plugin in "${PLUGINS[@]}"; do
  log "  Installing plugin: $plugin"
  java -jar "$JENKINS_CLI_JAR" -s "$JENKINS_URL" \
    -auth "admin:${ADMIN_PASS}" \
    install-plugin "$plugin" --deploy 2>/dev/null || warn "  Plugin $plugin may already be installed"
done

# ===========================================================================
# 6. Configure Jenkins Shared Library
# ===========================================================================
log "Configuring shared library (manual step required)..."
cat <<EOF

${YELLOW}==================================================================
MANUAL STEPS REQUIRED IN JENKINS UI:
==================================================================

1. Open Jenkins: http://$(curl -s ifconfig.me):${JENKINS_PORT}
   Initial password: ${ADMIN_PASS}

2. Manage Jenkins → System → Global Pipeline Libraries
   Add library:
     Name:            devopsunify-shared
     Default version: main
     Retrieval method: Modern SCM → Git
     URL:             https://github.com/YOUR_ORG/devopsunify.git
     Credentials:     (add your GitHub PAT)
     Library path:    jenkins/shared-library

3. Manage Jenkins → Credentials → System → Global
   Add these credentials:
     - Kind: AWS Credentials
       ID: aws-credentials
       Access Key / Secret Key from your IAM user

     - Kind: Secret file
       ID: eks-kubeconfig
       File: your ~/.kube/config for EKS

     - Kind: Secret text
       ID: sonar-token
       Value: your SonarQube token

     - Kind: Username with password
       ID: github-credentials
       Username: your GitHub login
       Password: your GitHub PAT

4. Manage Jenkins → Configure System → SonarQube servers
   Name: sonarqube
   URL:  http://YOUR_SONAR_HOST:9000
   Token: sonar-token (credential created above)

5. Restart Jenkins after plugin install:
   http://$(curl -s ifconfig.me):${JENKINS_PORT}/safeRestart
==================================================================
${NC}
EOF

log "Jenkins setup complete!"
log "Initial admin password: ${ADMIN_PASS}"
