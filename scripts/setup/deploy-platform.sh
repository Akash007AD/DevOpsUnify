#!/usr/bin/env bash
# =============================================================================
# DevOpsUnify — Production Deploy Script
# Builds and pushes Docker images for backend+frontend, deploys to EKS
# Usage: ./scripts/setup/deploy-platform.sh [aws-region] [ecr-registry]
# =============================================================================
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/../.."

AWS_REGION=${1:-${AWS_REGION:-ap-south-1}}
ECR_REGISTRY=${2:-${ECR_REGISTRY:-""}}
IMAGE_TAG=${IMAGE_TAG:-$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo "latest")}
NAMESPACE="devopsunify"

[[ -z "$ECR_REGISTRY" ]] && err "Set ECR_REGISTRY env var or pass as second argument"

BACKEND_IMAGE="${ECR_REGISTRY}/devopsunify-backend:${IMAGE_TAG}"
FRONTEND_IMAGE="${ECR_REGISTRY}/devopsunify-frontend:${IMAGE_TAG}"

# ===========================================================================
# 1. ECR login
# ===========================================================================
log "Logging in to ECR..."
aws ecr get-login-password --region "$AWS_REGION" | \
  docker login --username AWS --password-stdin "$ECR_REGISTRY"

# ===========================================================================
# 2. Build and push backend
# ===========================================================================
log "Building backend image: ${BACKEND_IMAGE}"
docker build -t "$BACKEND_IMAGE" "${REPO_ROOT}/backend"
docker push "$BACKEND_IMAGE"
docker tag "$BACKEND_IMAGE" "${ECR_REGISTRY}/devopsunify-backend:latest"
docker push "${ECR_REGISTRY}/devopsunify-backend:latest"

# ===========================================================================
# 3. Build and push frontend
# ===========================================================================
log "Building frontend image: ${FRONTEND_IMAGE}"
docker build -t "$FRONTEND_IMAGE" "${REPO_ROOT}/frontend"
docker push "$FRONTEND_IMAGE"
docker tag "$FRONTEND_IMAGE" "${ECR_REGISTRY}/devopsunify-frontend:latest"
docker push "${ECR_REGISTRY}/devopsunify-frontend:latest"

# ===========================================================================
# 4. Helm deploy
# ===========================================================================
log "Deploying to EKS namespace: ${NAMESPACE}..."
helm upgrade --install devopsunify-backend "${REPO_ROOT}/helm/platform-chart" \
  --namespace "$NAMESPACE" \
  --create-namespace \
  --set image.repository="${ECR_REGISTRY}/devopsunify-backend" \
  --set image.tag="$IMAGE_TAG" \
  --set service.targetPort=3000 \
  --set ingress.hosts[0].host="api.devopsunify.${AWS_REGION}.internal" \
  --wait --timeout 5m

helm upgrade --install devopsunify-frontend "${REPO_ROOT}/helm/platform-chart" \
  --namespace "$NAMESPACE" \
  --set image.repository="${ECR_REGISTRY}/devopsunify-frontend" \
  --set image.tag="$IMAGE_TAG" \
  --set service.targetPort=80 \
  --set ingress.hosts[0].host="devopsunify.${AWS_REGION}.internal" \
  --wait --timeout 5m

log "Deployment complete — image tag: ${IMAGE_TAG}"
kubectl get pods -n "$NAMESPACE"
