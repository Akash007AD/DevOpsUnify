#!/usr/bin/env bash
# =============================================================================
# DevOpsUnify — Bootstrap Script
# Installs all required tools on Ubuntu 22.04 / Amazon Linux 2023
# Run as a non-root user with sudo privileges
# Usage: ./scripts/install/bootstrap.sh
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; exit 1; }
info() { echo -e "${CYAN}[i]${NC} $*"; }

# Detect OS
if   [[ -f /etc/os-release ]]; then source /etc/os-release; OS=$ID
else err "Cannot detect OS"; fi

ARCH=$(uname -m)
[[ "$ARCH" == "x86_64" ]] && ARCH_ALT="amd64" || ARCH_ALT="arm64"

log "DevOpsUnify Bootstrap — OS: $OS / Arch: $ARCH"
echo "=================================================="

# ===========================================================================
# 1. System packages
# ===========================================================================
install_system_packages() {
  log "Installing system packages..."
  if [[ "$OS" == "ubuntu" ]] || [[ "$OS" == "debian" ]]; then
    sudo apt-get update -qq
    sudo apt-get install -y -qq \
      curl wget git unzip jq make build-essential \
      apt-transport-https ca-certificates gnupg lsb-release \
      software-properties-common python3 python3-pip \
      postgresql-client
  elif [[ "$OS" == "amzn" ]] || [[ "$OS" == "rhel" ]] || [[ "$OS" == "centos" ]]; then
    sudo yum update -y -q
    sudo yum install -y -q \
      curl wget git unzip jq make gcc python3 python3-pip \
      postgresql15
  fi
  log "System packages installed"
}

# ===========================================================================
# 2. Node.js 20 LTS
# ===========================================================================
install_node() {
  if command -v node &>/dev/null; then
    warn "Node.js $(node -v) already installed — skipping"
    return
  fi
  log "Installing Node.js 20 LTS..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
  if [[ "$OS" == "ubuntu" ]] || [[ "$OS" == "debian" ]]; then
    sudo apt-get install -y nodejs
  else
    sudo yum install -y nodejs20
  fi
  log "Node.js $(node -v) installed"
}

# ===========================================================================
# 3. Docker
# ===========================================================================
install_docker() {
  if command -v docker &>/dev/null; then
    warn "Docker $(docker --version | cut -d' ' -f3) already installed — skipping"
    return
  fi
  log "Installing Docker..."
  curl -fsSL https://get.docker.com | sudo bash
  sudo usermod -aG docker "$USER"
  sudo systemctl enable --now docker
  log "Docker installed — NOTE: log out and back in for docker group to take effect"
}

# ===========================================================================
# 4. kubectl
# ===========================================================================
install_kubectl() {
  if command -v kubectl &>/dev/null; then
    warn "kubectl $(kubectl version --client --short 2>/dev/null | head -1) already installed"
    return
  fi
  log "Installing kubectl..."
  KUBECTL_VERSION=$(curl -fsSL https://dl.k8s.io/release/stable.txt)
  curl -fsSLo /tmp/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH_ALT}/kubectl"
  chmod +x /tmp/kubectl
  sudo mv /tmp/kubectl /usr/local/bin/kubectl
  log "kubectl ${KUBECTL_VERSION} installed"
}

# ===========================================================================
# 5. Helm 3
# ===========================================================================
install_helm() {
  if command -v helm &>/dev/null; then
    warn "Helm $(helm version --short) already installed"
    return
  fi
  log "Installing Helm 3..."
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  log "Helm $(helm version --short) installed"
}

# ===========================================================================
# 6. Terraform
# ===========================================================================
install_terraform() {
  if command -v terraform &>/dev/null; then
    warn "Terraform $(terraform version -json | jq -r .terraform_version) already installed"
    return
  fi
  log "Installing Terraform 1.7..."
  TF_VERSION="1.7.4"
  curl -fsSLo /tmp/terraform.zip \
    "https://releases.hashicorp.com/terraform/${TF_VERSION}/terraform_${TF_VERSION}_linux_${ARCH_ALT}.zip"
  unzip -q /tmp/terraform.zip -d /tmp/
  sudo mv /tmp/terraform /usr/local/bin/terraform
  rm -f /tmp/terraform.zip
  log "Terraform $(terraform version -json | jq -r .terraform_version) installed"
}

# ===========================================================================
# 7. AWS CLI v2
# ===========================================================================
install_awscli() {
  if command -v aws &>/dev/null; then
    warn "AWS CLI $(aws --version 2>&1 | cut -d' ' -f1) already installed"
    return
  fi
  log "Installing AWS CLI v2..."
  curl -fsSLo /tmp/awscliv2.zip \
    "https://awscli.amazonaws.com/awscli-exe-linux-${ARCH}.zip"
  unzip -q /tmp/awscliv2.zip -d /tmp/
  sudo /tmp/aws/install
  rm -rf /tmp/aws /tmp/awscliv2.zip
  log "AWS CLI $(aws --version 2>&1) installed"
}

# ===========================================================================
# 8. Trivy
# ===========================================================================
install_trivy() {
  if command -v trivy &>/dev/null; then
    warn "Trivy $(trivy --version | head -1) already installed"
    return
  fi
  log "Installing Trivy..."
  curl -fsSL https://aquasecurity.github.io/trivy-repo/deb/public.key | \
    sudo gpg --dearmor -o /usr/share/keyrings/trivy.gpg
  echo "deb [signed-by=/usr/share/keyrings/trivy.gpg] https://aquasecurity.github.io/trivy-repo/deb generic main" | \
    sudo tee /etc/apt/sources.list.d/trivy.list
  if [[ "$OS" == "ubuntu" ]] || [[ "$OS" == "debian" ]]; then
    sudo apt-get update -qq && sudo apt-get install -y trivy
  else
    # RPM-based fallback
    TRIVY_VERSION=$(curl -fsSL https://api.github.com/repos/aquasecurity/trivy/releases/latest | jq -r .tag_name | tr -d v)
    curl -fsSLo /tmp/trivy.rpm \
      "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_Linux-64bit.rpm"
    sudo rpm -ivh /tmp/trivy.rpm
  fi
  log "Trivy $(trivy --version | head -1) installed"
}

# ===========================================================================
# 9. eksctl
# ===========================================================================
install_eksctl() {
  if command -v eksctl &>/dev/null; then
    warn "eksctl $(eksctl version) already installed"
    return
  fi
  log "Installing eksctl..."
  curl -fsSLo /tmp/eksctl.tar.gz \
    "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_${ARCH_ALT}.tar.gz"
  tar -xzf /tmp/eksctl.tar.gz -C /tmp/
  sudo mv /tmp/eksctl /usr/local/bin/eksctl
  rm -f /tmp/eksctl.tar.gz
  log "eksctl $(eksctl version) installed"
}

# ===========================================================================
# 10. SonarQube Scanner CLI
# ===========================================================================
install_sonar_scanner() {
  if command -v sonar-scanner &>/dev/null; then
    warn "sonar-scanner already installed"
    return
  fi
  log "Installing SonarQube Scanner CLI..."
  SONAR_VERSION="5.0.1.3006"
  curl -fsSLo /tmp/sonar-scanner.zip \
    "https://binaries.sonarsource.com/Distribution/sonar-scanner-cli/sonar-scanner-cli-${SONAR_VERSION}-linux.zip"
  sudo unzip -q /tmp/sonar-scanner.zip -d /opt/
  sudo ln -sf "/opt/sonar-scanner-${SONAR_VERSION}-linux/bin/sonar-scanner" /usr/local/bin/sonar-scanner
  rm -f /tmp/sonar-scanner.zip
  log "sonar-scanner installed"
}

# ===========================================================================
# Run all installers
# ===========================================================================
install_system_packages
install_node
install_docker
install_kubectl
install_helm
install_terraform
install_awscli
install_trivy
install_eksctl
install_sonar_scanner

# ===========================================================================
# Verify installations
# ===========================================================================
echo ""
log "=== Verification ==="
declare -A tools=(
  ["node"]="node --version"
  ["npm"]="npm --version"
  ["docker"]="docker --version"
  ["kubectl"]="kubectl version --client --short"
  ["helm"]="helm version --short"
  ["terraform"]="terraform version -json | jq -r .terraform_version"
  ["aws"]="aws --version"
  ["trivy"]="trivy --version"
  ["eksctl"]="eksctl version"
  ["sonar-scanner"]="sonar-scanner --version"
)
for tool in "${!tools[@]}"; do
  if command -v "$tool" &>/dev/null; then
    version=$(eval "${tools[$tool]}" 2>/dev/null | head -1)
    echo -e "  ${GREEN}✓${NC} $tool — $version"
  else
    echo -e "  ${RED}✗${NC} $tool — NOT FOUND"
  fi
done

echo ""
log "Bootstrap complete! Next step: cp backend/.env.example backend/.env && edit it"
warn "If docker group was added, you must log out and back in before running docker commands"
