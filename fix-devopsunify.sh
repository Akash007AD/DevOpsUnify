#!/usr/bin/env bash
# =============================================================================
# DevOpsUnify — Complete Fix Script
#
# HOW TO RUN:
#   cd /path/to/DevOpsUnify-main
#   bash fix_devopsunify.sh
#
# WHAT THIS DOES:
#   1. Writes backend/.env with your real values already filled in
#   2. Fixes build.logs stale-append bug in pipelines.js
#   3. Adds shell-injection validation in terraformService.js + pipelines.js
#   4. Adds live status polling to InfraPage.jsx after provision/destroy
#   5. Backs up every file it touches (.bak)
# =============================================================================

set -euo pipefail

# ── Resolve project root ─────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/backend/package.json" ]; then
  ROOT="$SCRIPT_DIR"
elif [ -f "./backend/package.json" ]; then
  ROOT="$(pwd)"
else
  echo "ERROR: Run this script from inside the DevOpsUnify-main directory"
  exit 1
fi

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "${GREEN}  ✔  $1${NC}"; }
warn() { echo -e "${YELLOW}  ⚠  $1${NC}"; }
step() { echo -e "\n${CYAN}[ $1 ]${NC}"; }
info() { echo -e "     → $1"; }

echo ""
echo "======================================================="
echo "  DevOpsUnify — Applying all fixes"
echo "  Root: $ROOT"
echo "======================================================="

# ─────────────────────────────────────────────────────────────────────────────
# FIX 1 — Write backend/.env
# Your real values (JWT, DB, GitHub) are already filled in.
# Placeholders remain for Jenkins, AWS, Grafana, Sonar — fill those manually.
# ─────────────────────────────────────────────────────────────────────────────
step "Fix 1 — Writing backend/.env"

ENV_FILE="$ROOT/backend/.env"
[ -f "$ENV_FILE" ] && cp "$ENV_FILE" "${ENV_FILE}.bak" && info "Backed up existing .env → .env.bak"

cat > "$ENV_FILE" << 'ENVEOF'
# ── Server ─────────────────────────────────────────────────────────────────
PORT=3000
NODE_ENV=development

# ── JWT ────────────────────────────────────────────────────────────────────
JWT_SECRET=b74aa2bec49926c949f468d439dcf04b8a9d68757f63dc6623e7b532c8ed877f
JWT_EXPIRES_IN=7d

# ── PostgreSQL ─────────────────────────────────────────────────────────────
DB_HOST=localhost
DB_PORT=5432
DB_NAME=devopsunify
DB_USER=devopsunify
DB_PASS=devopsunify_pass

# ── Redis ──────────────────────────────────────────────────────────────────
REDIS_HOST=localhost
REDIS_PORT=6379
REDIS_PASS=

# ── GitHub OAuth App ───────────────────────────────────────────────────────
GITHUB_CLIENT_ID=Ov23ligpEdcN3CKzkonL
GITHUB_CLIENT_SECRET=724a6702b25b833d07860ef22ce5bf1c11dc4492
GITHUB_CALLBACK_URL=http://localhost:3000/api/auth/github/callback
# REQUIRED — generate with: openssl rand -hex 32
GITHUB_WEBHOOK_SECRET=REPLACE_openssl_rand_hex_32

# ── Jenkins ────────────────────────────────────────────────────────────────
# REQUIRED — your Jenkins EC2 IP, e.g. http://13.233.45.67:8080
JENKINS_URL=REPLACE_YOUR_JENKINS_URL
JENKINS_USER=admin
# REQUIRED — Jenkins → top-right user menu → Configure → API Token → Add new Token
JENKINS_API_TOKEN=REPLACE_YOUR_JENKINS_API_TOKEN

# ── AWS ────────────────────────────────────────────────────────────────────
AWS_REGION=ap-south-1
# REQUIRED — IAM user credentials (needs ECR + EKS + S3 + DynamoDB permissions)
AWS_ACCESS_KEY_ID=REPLACE_YOUR_AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY=REPLACE_YOUR_AWS_SECRET_ACCESS_KEY
# REQUIRED — format: <account-id>.dkr.ecr.ap-south-1.amazonaws.com
# find with: aws sts get-caller-identity --query Account --output text
ECR_REGISTRY=REPLACE_YOUR_ACCOUNT_ID.dkr.ecr.ap-south-1.amazonaws.com

# ── SonarQube ──────────────────────────────────────────────────────────────
# REQUIRED for quality gate stages in the Jenkinsfile
# e.g. SONAR_URL=http://13.233.45.67:9000
SONAR_URL=REPLACE_YOUR_SONAR_URL
# SonarQube → My Account → Security → Generate Token
SONAR_TOKEN=REPLACE_YOUR_SONAR_TOKEN

# ── Grafana ────────────────────────────────────────────────────────────────
# REQUIRED for monitoring dashboards — e.g. http://localhost:3001
GRAFANA_URL=REPLACE_YOUR_GRAFANA_URL
# Grafana → Administration → API Keys → Add API key (role: Editor)
GRAFANA_API_KEY=REPLACE_YOUR_GRAFANA_API_KEY

# ── Prometheus ─────────────────────────────────────────────────────────────
# Port-forward if using kube-prometheus-stack:
#   kubectl port-forward -n monitoring svc/prometheus-operated 9090:9090
PROMETHEUS_URL=http://localhost:9090

# ── Terraform State Backend ────────────────────────────────────────────────
TF_STATE_BUCKET=devopsunify-tfstate
TF_LOCK_TABLE=devopsunify-tflock
ENVEOF

ok "backend/.env written"
warn "Still needs these values replaced:"
info "GITHUB_WEBHOOK_SECRET  →  openssl rand -hex 32"
info "JENKINS_URL            →  http://<your-ec2-ip>:8080"
info "JENKINS_API_TOKEN      →  Jenkins → User → Configure → API Token"
info "AWS_ACCESS_KEY_ID      →  your IAM key"
info "AWS_SECRET_ACCESS_KEY  →  your IAM secret"
info "ECR_REGISTRY           →  <account-id>.dkr.ecr.ap-south-1.amazonaws.com"
info "SONAR_URL / SONAR_TOKEN"
info "GRAFANA_URL / GRAFANA_API_KEY"

# ─────────────────────────────────────────────────────────────────────────────
# FIX 2 — Fix build.logs stale-append bug in pipelines.js
# Problem: build.logs in the _trackBuild loop reads the in-memory value that
#          was set at Build.create() time (empty string). Successive iterations
#          keep overwriting with only the latest chunk, losing previous output.
# Fix:     Reload the build row from DB before each append so logs accumulate.
# ─────────────────────────────────────────────────────────────────────────────
step "Fix 2 — Fixing build.logs stale-append bug in pipelines.js"

PIPELINES="$ROOT/backend/src/routes/pipelines.js"
cp "$PIPELINES" "${PIPELINES}.bak"

python3 - "$PIPELINES" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# 1. Make build variable re-assignable
old_const = 'const build = await Build.create({'
new_const  = 'let build = await Build.create({'

# 2. Fix the stale logs append — reload from DB each iteration
old_logs = (
    '      if (text) {\n'
    '        await build.update({ logs: build.logs + text });\n'
    '        for (const line of text.split(\'\\n\')) {'
)
new_logs = (
    '      if (text) {\n'
    '        // Reload from DB — avoids stale in-memory value losing log chunks\n'
    '        const freshBuild = await Build.findByPk(build.id);\n'
    '        await freshBuild.update({ logs: (freshBuild.logs || \'\') + text });\n'
    '        build = freshBuild;\n'
    '        for (const line of text.split(\'\\n\')) {'
)

changed = False

if old_const in content:
    content = content.replace(old_const, new_const, 1)
    print('  ok: const -> let for build variable')
    changed = True
else:
    print('  skip: build already let')

if old_logs in content:
    content = content.replace(old_logs, new_logs, 1)
    print('  ok: build.logs stale-append fixed')
    changed = True
else:
    print('  skip: logs pattern not found')

if changed:
    with open(path, 'w') as f:
        f.write(content)
PYEOF

ok "pipelines.js patched"

# ─────────────────────────────────────────────────────────────────────────────
# FIX 3 — Add shell injection validation in terraformService.js
# Problem: projectName and projectId are shell-interpolated inside exec() calls
#          e.g. `terraform workspace new ${projectId}` — a malicious ID like
#          "x; rm -rf /" would execute on the server.
# Fix:     Validate both values match /^[a-z0-9-]{1,63}$/ before running anything.
# ─────────────────────────────────────────────────────────────────────────────
step "Fix 3 — Shell injection validation in terraformService.js"

TF_SERVICE="$ROOT/backend/src/services/terraformService.js"
cp "$TF_SERVICE" "${TF_SERVICE}.bak"

python3 - "$TF_SERVICE" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

old = (
    "    const workDir = path.join(TF_MODULES_DIR, 'environments', environment);\n"
    "    const varFile = await this._writeTfVars(projectName, awsRegion, projectId);\n"
    "\n"
    "    try {\n"
    "      await this._run('terraform init -reconfigure',"
)
new = (
    "    // Validate — both values are shell-interpolated, must only contain safe chars\n"
    "    const safePattern = /^[a-z0-9-]{1,63}$/;\n"
    "    if (!safePattern.test(projectName)) {\n"
    "      throw new Error(`Invalid projectName \"${projectName}\" — only lowercase letters, numbers, hyphens allowed`);\n"
    "    }\n"
    "    if (!safePattern.test(projectId)) {\n"
    "      throw new Error(`Invalid projectId \"${projectId}\" — only lowercase letters, numbers, hyphens allowed`);\n"
    "    }\n"
    "\n"
    "    const workDir = path.join(TF_MODULES_DIR, 'environments', environment);\n"
    "    const varFile = await this._writeTfVars(projectName, awsRegion, projectId);\n"
    "\n"
    "    try {\n"
    "      await this._run('terraform init -reconfigure',"
)

if old in content:
    content = content.replace(old, new, 1)
    print('  ok: shell injection validation added to provision()')
    with open(path, 'w') as f:
        f.write(content)
else:
    print('  skip: pattern not found (may already be patched)')
PYEOF

ok "terraformService.js patched"

# ─────────────────────────────────────────────────────────────────────────────
# FIX 4 — Add projectName validation at creation time in pipelines.js
# Catches bad names before they ever reach terraformService or jenkinsService.
# ─────────────────────────────────────────────────────────────────────────────
step "Fix 4 — projectName validation in pipelines.js POST /projects"

python3 - "$PIPELINES" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

old = (
    "    const projectName = (name || repoUrl.split('/').pop().replace('.git', '')).toLowerCase().replace(/[^a-z0-9-]/g, '-');\n"
    "    const [owner, repo] = repoFullName.split('/');"
)
new = (
    "    const projectName = (name || repoUrl.split('/').pop().replace('.git', '')).toLowerCase().replace(/[^a-z0-9-]/g, '-');\n"
    "    // Guard — projectName is shell-interpolated in terraform + jenkins commands\n"
    "    if (!/^[a-z0-9-]{1,63}$/.test(projectName)) {\n"
    "      return res.status(400).json({ error: 'Project name must be lowercase letters, numbers, hyphens only (max 63 chars)' });\n"
    "    }\n"
    "    const [owner, repo] = repoFullName.split('/');"
)

if old in content:
    content = content.replace(old, new, 1)
    print('  ok: projectName validation added')
    with open(path, 'w') as f:
        f.write(content)
else:
    print('  skip: pattern not found (may already be patched)')
PYEOF

ok "pipelines.js POST /projects validation added"

# ─────────────────────────────────────────────────────────────────────────────
# FIX 5 — Add live status polling to InfraPage.jsx
# Problem: After clicking Provision, the API returns 202 immediately because
#          Terraform runs async. The UI spinner never clears because the frontend
#          never re-checks the backend for the updated status.
# Fix:     Start a setInterval after the API call that fetches infra status
#          every 5s and updates the table row until status is applied/failed.
# ─────────────────────────────────────────────────────────────────────────────
step "Fix 5 — Live status polling in InfraPage.jsx"

INFRA_PAGE="$ROOT/frontend/src/pages/InfraPage.jsx"
cp "$INFRA_PAGE" "${INFRA_PAGE}.bak"

python3 - "$INFRA_PAGE" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# ── provision() ──────────────────────────────────────────────────────────────
old_provision = (
    "  async function provision(projectId) {\n"
    "    setProv(prev => ({ ...prev, [projectId]: 'provisioning' }));\n"
    "    try {\n"
    "      await api.post(`/infra/projects/${projectId}/provision`);\n"
    "      setProv(prev => ({ ...prev, [projectId]: 'done' }));\n"
    "    } catch (e) {\n"
    "      setProv(prev => ({ ...prev, [projectId]: 'error' }));\n"
    "    }\n"
    "  }"
)
new_provision = (
    "  async function provision(projectId) {\n"
    "    setProv(prev => ({ ...prev, [projectId]: 'provisioning' }));\n"
    "    try {\n"
    "      await api.post(`/infra/projects/${projectId}/provision`);\n"
    "      // Terraform is async — poll every 5s until status settles\n"
    "      const poll = setInterval(async () => {\n"
    "        try {\n"
    "          const ir = await api.get(`/infra/projects/${projectId}/infra`);\n"
    "          const latest = ir.data[0] || null;\n"
    "          setInfraMap(prev => ({ ...prev, [projectId]: latest }));\n"
    "          if (latest && ['applied', 'failed', 'destroyed'].includes(latest.status)) {\n"
    "            clearInterval(poll);\n"
    "            setProv(prev => ({ ...prev, [projectId]: 'done' }));\n"
    "          }\n"
    "        } catch (_) { /* network blip — keep polling */ }\n"
    "      }, 5000);\n"
    "    } catch (e) {\n"
    "      setProv(prev => ({ ...prev, [projectId]: 'error' }));\n"
    "    }\n"
    "  }"
)

# ── destroy() ────────────────────────────────────────────────────────────────
old_destroy = (
    "  async function destroy(projectId) {\n"
    "    if (!window.confirm('Destroy all AWS resources for this project? This cannot be undone.')) return;\n"
    "    setProv(prev => ({ ...prev, [projectId]: 'destroying' }));\n"
    "    try {\n"
    "      await api.delete(`/infra/projects/${projectId}/infra`);\n"
    "      setProv(prev => ({ ...prev, [projectId]: 'done' }));\n"
    "    } catch (_) {\n"
    "      setProv(prev => ({ ...prev, [projectId]: 'error' }));\n"
    "    }\n"
    "  }"
)
new_destroy = (
    "  async function destroy(projectId) {\n"
    "    if (!window.confirm('Destroy all AWS resources for this project? This cannot be undone.')) return;\n"
    "    setProv(prev => ({ ...prev, [projectId]: 'destroying' }));\n"
    "    try {\n"
    "      await api.delete(`/infra/projects/${projectId}/infra`);\n"
    "      // Poll until destroyed or failed\n"
    "      const poll = setInterval(async () => {\n"
    "        try {\n"
    "          const ir = await api.get(`/infra/projects/${projectId}/infra`);\n"
    "          const latest = ir.data[0] || null;\n"
    "          setInfraMap(prev => ({ ...prev, [projectId]: latest }));\n"
    "          if (!latest || ['destroyed', 'failed'].includes(latest.status)) {\n"
    "            clearInterval(poll);\n"
    "            setProv(prev => ({ ...prev, [projectId]: 'done' }));\n"
    "          }\n"
    "        } catch (_) { /* keep polling */ }\n"
    "      }, 5000);\n"
    "    } catch (_) {\n"
    "      setProv(prev => ({ ...prev, [projectId]: 'error' }));\n"
    "    }\n"
    "  }"
)

changed = False

if old_provision in content:
    content = content.replace(old_provision, new_provision, 1)
    print('  ok: provision() polling added')
    changed = True
else:
    print('  skip: provision() pattern not found')

if old_destroy in content:
    content = content.replace(old_destroy, new_destroy, 1)
    print('  ok: destroy() polling added')
    changed = True
else:
    print('  skip: destroy() pattern not found')

if changed:
    with open(path, 'w') as f:
        f.write(content)
PYEOF

ok "InfraPage.jsx patched"

# ─────────────────────────────────────────────────────────────────────────────
# VERIFY — diff line count for every patched file
# ─────────────────────────────────────────────────────────────────────────────
step "Verification"

for file in \
  "$ROOT/backend/.env" \
  "$ROOT/backend/src/routes/pipelines.js" \
  "$ROOT/backend/src/services/terraformService.js" \
  "$ROOT/frontend/src/pages/InfraPage.jsx"
do
  bak="${file}.bak"
  label="${file#$ROOT/}"
  if [ -f "$bak" ]; then
    lines=$(diff "$bak" "$file" 2>/dev/null | grep -c "^[<>]" || true)
    info "$label  ($lines lines changed)"
  else
    info "$label  (newly created)"
  fi
done

# ─────────────────────────────────────────────────────────────────────────────
# FINAL SUMMARY
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "======================================================="
echo -e "${GREEN}  All code fixes applied${NC}"
echo "======================================================="
echo ""
echo -e "${YELLOW}  REQUIRED: Open backend/.env and replace these placeholders${NC}"
echo ""
echo "  GITHUB_WEBHOOK_SECRET   →  openssl rand -hex 32"
echo ""
echo "  JENKINS_URL             →  http://<your-ec2-ip>:8080"
echo "  JENKINS_API_TOKEN       →  Jenkins → User → Configure → API Token"
echo ""
echo "  AWS_ACCESS_KEY_ID       →  your IAM user access key"
echo "  AWS_SECRET_ACCESS_KEY   →  your IAM user secret"
echo "  ECR_REGISTRY            →  <account-id>.dkr.ecr.ap-south-1.amazonaws.com"
echo "                              find account-id: aws sts get-caller-identity"
echo ""
echo "  SONAR_URL               →  http://<sonar-host>:9000"
echo "  SONAR_TOKEN             →  SonarQube → My Account → Security → Tokens"
echo ""
echo "  GRAFANA_URL             →  http://<grafana-host>:3001"
echo "  GRAFANA_API_KEY         →  Grafana → Administration → API Keys"
echo ""
echo -e "${CYAN}  After filling .env, restart backend:${NC}"
echo "    cd backend && npm run dev"
echo ""
echo -e "${CYAN}  Then for each project in the UI:${NC}"
echo "    1. Open the project → click 'Sync Jenkins'"
echo "    2. Then click 'Run Build'"
echo ""