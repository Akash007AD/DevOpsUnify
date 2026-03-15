#!/usr/bin/env bash
# =============================================================================
# DevOpsUnify — SonarQube Setup Script
# Runs SonarQube Community Edition in Docker with persistent storage
# Usage: ./scripts/setup/setup-sonarqube.sh
# =============================================================================
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }

SONAR_PORT=${SONAR_PORT:-9000}
SONAR_DATA_DIR=${SONAR_DATA_DIR:-/opt/sonarqube}

# Kernel tuning required by Elasticsearch (inside SonarQube)
log "Tuning kernel parameters for Elasticsearch..."
sudo sysctl -w vm.max_map_count=524288
sudo sysctl -w fs.file-max=131072
echo "vm.max_map_count=524288" | sudo tee -a /etc/sysctl.conf
echo "fs.file-max=131072"      | sudo tee -a /etc/sysctl.conf

# Create data dirs
sudo mkdir -p "${SONAR_DATA_DIR}"/{data,logs,extensions,conf}
sudo chmod 777 "${SONAR_DATA_DIR}"/{data,logs,extensions,conf}

# Stop existing container if any
docker rm -f sonarqube 2>/dev/null || true

log "Starting SonarQube 10 Community Edition..."
docker run -d \
  --name sonarqube \
  --restart unless-stopped \
  -p "${SONAR_PORT}:9000" \
  -e SONAR_JDBC_URL="jdbc:h2:tcp://localhost/sonar" \
  -v "${SONAR_DATA_DIR}/data:/opt/sonarqube/data" \
  -v "${SONAR_DATA_DIR}/logs:/opt/sonarqube/logs" \
  -v "${SONAR_DATA_DIR}/extensions:/opt/sonarqube/extensions" \
  sonarqube:10-community

# Wait for SonarQube to be ready
log "Waiting for SonarQube to be ready (this can take 2-3 minutes)..."
timeout 180 bash -c \
  "until curl -sf http://localhost:${SONAR_PORT}/api/system/status | grep -q '\"status\":\"UP\"'; do
     echo '  Waiting...'; sleep 5
   done"

PUBLIC_IP=$(curl -s --max-time 5 ifconfig.me || echo "localhost")
log "SonarQube is ready!"
log "  URL:      http://${PUBLIC_IP}:${SONAR_PORT}"
log "  Login:    admin / admin  (CHANGE ON FIRST LOGIN)"

cat <<EOF

${YELLOW}==================================================================
POST-INSTALL STEPS:
==================================================================
1. Open http://${PUBLIC_IP}:${SONAR_PORT}
2. Login admin/admin → change password immediately
3. Administration → Security → Generate Token
   Copy the token → paste into backend/.env as SONAR_TOKEN
4. For each project, DevOpsUnify will auto-create projects
   via API using the SONAR_TOKEN
==================================================================
${NC}
EOF
