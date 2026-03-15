#!/usr/bin/env bash
# =============================================================================
# DevOpsUnify — EKS kubeconfig + cluster bootstrap
# Run AFTER terraform apply completes
# Usage: ./scripts/aws/setup-eks.sh ap-south-1 devopsunify
# =============================================================================
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }

AWS_REGION=${1:-ap-south-1}
CLUSTER_NAME=${2:-devopsunify}

log "Configuring kubectl for EKS cluster: ${CLUSTER_NAME}"
aws eks update-kubeconfig \
  --region "$AWS_REGION" \
  --name  "$CLUSTER_NAME" \
  --alias "$CLUSTER_NAME"

log "Testing cluster access..."
kubectl cluster-info
kubectl get nodes

# ===========================================================================
# Apply base manifests
# ===========================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/../.."

log "Applying namespaces..."
kubectl apply -f "${REPO_ROOT}/kubernetes/namespaces/namespaces.yaml"

log "Applying Jenkins RBAC..."
kubectl apply -f "${REPO_ROOT}/kubernetes/rbac/jenkins-rbac.yaml"

log "Applying Prometheus alert rules..."
kubectl apply -f "${REPO_ROOT}/kubernetes/monitoring/prometheus-rules.yaml" || \
  warn "Prometheus CRDs not ready yet — run this again after monitoring stack is up"

# ===========================================================================
# Install ingress-nginx
# ===========================================================================
log "Installing ingress-nginx..."
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
helm repo update
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --set controller.service.type=LoadBalancer \
  --wait --timeout 5m

# ===========================================================================
# Install AWS Load Balancer Controller
# ===========================================================================
log "Installing AWS Load Balancer Controller..."
helm repo add eks https://aws.github.io/eks-charts 2>/dev/null || true
helm repo update

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
VPC_ID=$(aws eks describe-cluster \
  --name "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --query "cluster.resourcesVpcConfig.vpcId" \
  --output text)

helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --namespace kube-system \
  --set clusterName="$CLUSTER_NAME" \
  --set serviceAccount.create=true \
  --set region="$AWS_REGION" \
  --set vpcId="$VPC_ID" \
  --wait --timeout 5m

# ===========================================================================
# Extract Jenkins kubeconfig secret for Jenkins credential store
# ===========================================================================
log "Extracting Jenkins deployer token..."
TOKEN=$(kubectl get secret jenkins-deployer-token \
  -n jenkins \
  -o jsonpath='{.data.token}' | base64 -d)

CA=$(kubectl get secret jenkins-deployer-token \
  -n jenkins \
  -o jsonpath='{.data.ca\.crt}')

ENDPOINT=$(aws eks describe-cluster \
  --name "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --query "cluster.endpoint" \
  --output text)

KUBECONFIG_OUT="${REPO_ROOT}/.jenkins-kubeconfig"
cat > "$KUBECONFIG_OUT" <<KUBECONFIG
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: ${CA}
    server: ${ENDPOINT}
  name: ${CLUSTER_NAME}
contexts:
- context:
    cluster: ${CLUSTER_NAME}
    user: jenkins-deployer
  name: ${CLUSTER_NAME}
current-context: ${CLUSTER_NAME}
users:
- name: jenkins-deployer
  user:
    token: ${TOKEN}
KUBECONFIG

chmod 600 "$KUBECONFIG_OUT"
log "Jenkins kubeconfig written to: ${KUBECONFIG_OUT}"
warn "Upload this file to Jenkins as a 'Secret file' credential with ID: eks-kubeconfig"

# ===========================================================================
# Add Helm repo for devopsunify charts
# ===========================================================================
log "Adding devopsunify Helm chart repo..."
helm repo add devopsunify "${REPO_ROOT}/helm/library-charts" 2>/dev/null || true

cat <<EOF

${GREEN}=============================================================
EKS setup complete!
=============================================================
Cluster:    ${CLUSTER_NAME}
Region:     ${AWS_REGION}
Kubeconfig: ${KUBECONFIG_OUT}

Next steps:
  1. Upload .jenkins-kubeconfig to Jenkins credentials (ID: eks-kubeconfig)
  2. Run ./scripts/setup/setup-sonarqube.sh on your SonarQube host
  3. cp backend/.env.example backend/.env  — fill in all values
  4. cd backend && npm install && npm start
  5. cd frontend && npm install && npm run dev
=============================================================
${NC}
EOF
