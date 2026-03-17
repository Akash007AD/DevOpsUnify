#!/usr/bin/env bash
# =============================================================================
# setup-jenkins-kubeconfig.sh
# Creates a self-contained kubeconfig (certs embedded, no local file paths)
# and adds it to Jenkins as a Secret file credential with ID: eks-kubeconfig
# =============================================================================
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; exit 1; }

# ── Config ────────────────────────────────────────────────────────────────────
JENKINS_URL="${JENKINS_URL:-http://localhost:8080}"
JENKINS_USER="${JENKINS_USER:-Akash}"
JENKINS_TOKEN="${JENKINS_TOKEN:-}"
KUBECONFIG_OUT="/tmp/jenkins-kubeconfig"
CREDENTIAL_ID="eks-kubeconfig"

# ── Step 1: Check minikube is running ─────────────────────────────────────────
log "Checking minikube status..."
if ! minikube status | grep -q "Running"; then
  warn "Minikube not running. Starting it..."
  minikube start
fi
log "Minikube is running."

# ── Step 2: Create flattened kubeconfig (certs embedded as base64) ────────────
log "Creating self-contained kubeconfig at $KUBECONFIG_OUT ..."
kubectl config view --minify --flatten > "$KUBECONFIG_OUT"
log "Kubeconfig written to $KUBECONFIG_OUT"
echo ""
cat "$KUBECONFIG_OUT"
echo ""

# ── Step 3: Ask for Jenkins token if not set ──────────────────────────────────
if [ -z "$JENKINS_TOKEN" ]; then
  echo -e "${YELLOW}Enter your Jenkins API token (from Jenkins → your user → Configure → API Token):${NC}"
  read -rs JENKINS_TOKEN
  echo ""
fi

# ── Step 4: Get Jenkins crumb (CSRF token) ────────────────────────────────────
log "Fetching Jenkins crumb..."
CRUMB_DATA=$(curl -sf --user "${JENKINS_USER}:${JENKINS_TOKEN}" \
  "${JENKINS_URL}/crumbIssuer/api/json") || err "Could not reach Jenkins at ${JENKINS_URL}. Is it running?"

CRUMB_FIELD=$(echo "$CRUMB_DATA" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['crumbRequestField'])")
CRUMB_VALUE=$(echo "$CRUMB_DATA" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['crumb'])")
log "Got crumb: $CRUMB_FIELD=$CRUMB_VALUE"

# ── Step 5: Check if credential already exists ────────────────────────────────
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  --user "${JENKINS_USER}:${JENKINS_TOKEN}" \
  "${JENKINS_URL}/credentials/store/system/domain/_/credential/${CREDENTIAL_ID}/")

if [ "$HTTP_STATUS" = "200" ]; then
  warn "Credential '${CREDENTIAL_ID}' already exists. Updating it..."

  # Update existing credential
  curl -sf --user "${JENKINS_USER}:${JENKINS_TOKEN}" \
    -H "${CRUMB_FIELD}: ${CRUMB_VALUE}" \
    -F "stapler-class=org.jenkinsci.plugins.plaincredentials.impl.FileCredentialsImpl" \
    -F "file=@${KUBECONFIG_OUT}" \
    -F "_.id=${CREDENTIAL_ID}" \
    -F "_.description=Minikube kubeconfig for local dev" \
    "${JENKINS_URL}/credentials/store/system/domain/_/credential/${CREDENTIAL_ID}/updateSubmit" \
    && log "Credential updated successfully." \
    || warn "Update via API failed — please upload manually (see instructions below)."
else
  log "Creating new credential '${CREDENTIAL_ID}'..."

  # Create new credential via XML
  XML="<org.jenkinsci.plugins.plaincredentials.impl.FileCredentialsImpl>
  <scope>GLOBAL</scope>
  <id>${CREDENTIAL_ID}</id>
  <description>Minikube kubeconfig for local dev</description>
  <fileName>kubeconfig</fileName>
  <secretBytes>$(base64 -w 0 "$KUBECONFIG_OUT")</secretBytes>
</org.jenkinsci.plugins.plaincredentials.impl.FileCredentialsImpl>"

  HTTP_CODE=$(curl -s -o /tmp/jenkins-cred-response.txt -w "%{http_code}" \
    --user "${JENKINS_USER}:${JENKINS_TOKEN}" \
    -H "${CRUMB_FIELD}: ${CRUMB_VALUE}" \
    -H "Content-Type: application/xml" \
    -d "$XML" \
    "${JENKINS_URL}/credentials/store/system/domain/_/createCredentials")

  if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ]; then
    log "Credential '${CREDENTIAL_ID}' created successfully!"
  else
    warn "API returned HTTP $HTTP_CODE. Response:"
    cat /tmp/jenkins-cred-response.txt
    echo ""
    warn "Automatic upload failed. Do it manually (instructions below)."
  fi
fi

# ── Step 6: Print manual fallback instructions ────────────────────────────────
echo ""
echo -e "${YELLOW}=================================================================="
echo "MANUAL FALLBACK (if automatic upload failed):"
echo "=================================================================="
echo ""
echo "1. Open Jenkins: ${JENKINS_URL}"
echo "2. Manage Jenkins → Credentials → System → Global credentials → Add"
echo "   Kind:        Secret file"
echo "   File:        upload  ${KUBECONFIG_OUT}"
echo "   ID:          ${CREDENTIAL_ID}"
echo "   Description: Minikube kubeconfig for local dev"
echo "3. Click Save"
echo -e "==================================================================${NC}"
echo ""
log "Done! Now run Build #9 from the DevOpsUnify UI."
