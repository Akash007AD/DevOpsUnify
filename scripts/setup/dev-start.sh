#!/usr/bin/env bash
# =============================================================================
# DevOpsUnify — Local Development Start Script
# Starts PostgreSQL + Redis via Docker, then backend + frontend
# Usage: ./scripts/setup/dev-start.sh
# =============================================================================
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
info() { echo -e "${CYAN}[i]${NC} $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/../.."

# Ensure .env exists
if [[ ! -f "${REPO_ROOT}/backend/.env" ]]; then
  warn ".env not found — copying from .env.example"
  cp "${REPO_ROOT}/backend/.env.example" "${REPO_ROOT}/backend/.env"
  warn "Edit backend/.env before continuing"
  exit 1
fi

# ===========================================================================
# Start infrastructure services via Docker
# ===========================================================================
log "Starting PostgreSQL..."
docker rm -f devopsunify-postgres 2>/dev/null || true
docker run -d \
  --name devopsunify-postgres \
  -e POSTGRES_DB=devopsunify \
  -e POSTGRES_USER=devopsunify \
  -e POSTGRES_PASSWORD=devopsunify_pass \
  -p 5432:5432 \
  -v devopsunify-pgdata:/var/lib/postgresql/data \
  postgres:15-alpine

log "Starting Redis..."
docker rm -f devopsunify-redis 2>/dev/null || true
docker run -d \
  --name devopsunify-redis \
  -p 6379:6379 \
  redis:7-alpine

# Wait for Postgres
log "Waiting for Postgres to be ready..."
timeout 30 bash -c \
  'until docker exec devopsunify-postgres pg_isready -U devopsunify > /dev/null 2>&1; do sleep 1; done'
log "PostgreSQL is ready"

# ===========================================================================
# Install npm dependencies
# ===========================================================================
log "Installing backend dependencies..."
cd "${REPO_ROOT}/backend" && npm install --silent

log "Installing frontend dependencies..."
cd "${REPO_ROOT}/frontend" && npm install --silent

# ===========================================================================
# Start backend + frontend in parallel
# ===========================================================================
log "Starting backend (port 3000) and frontend (port 5173)..."
cd "${REPO_ROOT}"

# Use trap to kill both on Ctrl+C
trap 'kill $(jobs -p) 2>/dev/null; exit 0' SIGINT SIGTERM

# Backend
(cd backend && npm run dev 2>&1 | sed 's/^/[backend] /') &
BACKEND_PID=$!

# Wait for backend
sleep 3

# Frontend
(cd frontend && npm run dev 2>&1 | sed 's/^/[frontend] /') &
FRONTEND_PID=$!

info ""
info "  Backend:  http://localhost:3000"
info "  Frontend: http://localhost:5173"
info "  API docs: http://localhost:3000/health"
info ""
info "  Press Ctrl+C to stop all services"
info ""

wait $BACKEND_PID $FRONTEND_PID
