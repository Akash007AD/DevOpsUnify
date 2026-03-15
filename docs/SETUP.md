# DevOpsUnify — Complete Setup Guide

This guide walks you from zero to a fully running DevOpsUnify platform.

---

## Prerequisites

| Tool | Minimum version | Purpose |
|------|----------------|---------|
| Git | 2.x | Repository management |
| Node.js | 20 LTS | Backend + frontend |
| Docker | 24.x | Local services + builds |
| AWS CLI | 2.x | AWS access |
| Terraform | 1.7+ | Infrastructure provisioning |
| kubectl | 1.28+ | Kubernetes access |
| Helm | 3.14+ | Chart deployments |
| Trivy | 0.49+ | Image scanning |

Install everything at once:
```bash
chmod +x scripts/install/bootstrap.sh
./scripts/install/bootstrap.sh
```

---

## Step 1 — AWS Credentials

```bash
aws configure
# AWS Access Key ID:     YOUR_KEY
# AWS Secret Access Key: YOUR_SECRET
# Default region:        ap-south-1
# Default output:        json
```

Verify:
```bash
aws sts get-caller-identity
```

---

## Step 2 — Bootstrap AWS Remote State

Creates the S3 bucket and DynamoDB table Terraform needs before it can run.

```bash
chmod +x scripts/aws/bootstrap-aws.sh
./scripts/aws/bootstrap-aws.sh ap-south-1 devopsunify
```

Copy the output values into `backend/.env`.

---

## Step 3 — GitHub OAuth App

1. Go to https://github.com/settings/developers → New OAuth App
2. Fill in:
   - Application name: `DevOpsUnify`
   - Homepage URL: `http://localhost:5173`
   - Callback URL: `http://localhost:3000/api/auth/github/callback`
3. Copy Client ID and Client Secret into `backend/.env`

Generate a webhook secret:
```bash
openssl rand -hex 32
# Paste as GITHUB_WEBHOOK_SECRET in backend/.env
```

---

## Step 4 — Configure Environment

```bash
cp backend/.env.example backend/.env
# Edit every value in backend/.env
nano backend/.env
```

Key values to fill:
```
GITHUB_CLIENT_ID=...
GITHUB_CLIENT_SECRET=...
GITHUB_WEBHOOK_SECRET=...
JWT_SECRET=$(openssl rand -hex 32)
```

Leave AWS, Jenkins, SonarQube, Grafana values for now — fill after provisioning.

---

## Step 5 — Local Dev (No AWS)

Start everything locally with Docker Compose:

```bash
# Option A: Docker Compose (full stack including Jenkins, SonarQube, Grafana)
docker compose up -d

# Option B: Minimal local dev (just DB + Redis, run app with npm)
chmod +x scripts/setup/dev-start.sh
./scripts/setup/dev-start.sh
```

Access:
- Frontend:  http://localhost:5173
- Backend:   http://localhost:3000
- Jenkins:   http://localhost:8080
- SonarQube: http://localhost:9000
- Grafana:   http://localhost:3001  (admin / DevOpsUnify2024)
- Prometheus:http://localhost:9090

---

## Step 6 — Provision AWS Infrastructure

```bash
cd terraform/environments/dev

terraform init \
  -backend-config="bucket=devopsunify-tfstate-ACCOUNT_ID" \
  -backend-config="key=dev/terraform.tfstate" \
  -backend-config="region=ap-south-1" \
  -backend-config="dynamodb_table=devopsunify-tflock"

terraform plan
terraform apply
```

This provisions (takes ~15 minutes):
- VPC with public + private subnets across 2 AZs
- EKS cluster (2x t3.medium nodes)
- ECR repository
- S3 bucket + DynamoDB (for state)
- kube-prometheus-stack (Prometheus + Grafana + Alertmanager)

Copy Terraform outputs into `backend/.env`:
```bash
terraform output cluster_name      # → add to .env
terraform output ecr_registry      # → ECR_REGISTRY in .env
terraform output ecr_repository_url
```

---

## Step 7 — Set Up EKS Access + Base Manifests

```bash
chmod +x scripts/aws/setup-eks.sh
./scripts/aws/setup-eks.sh ap-south-1 devopsunify
```

This:
- Configures kubectl
- Applies namespaces + RBAC
- Installs ingress-nginx
- Generates `.jenkins-kubeconfig` for Jenkins

---

## Step 8 — Set Up Jenkins on EC2

Launch a `t3.medium` EC2 instance (Ubuntu 22.04), then:

```bash
# Copy the script to your EC2
scp scripts/setup/setup-jenkins.sh ubuntu@JENKINS_EC2_IP:~

# SSH and run
ssh ubuntu@JENKINS_EC2_IP
chmod +x setup-jenkins.sh
./setup-jenkins.sh
```

Then follow the **manual steps** printed at the end:
1. Open Jenkins UI
2. Add the shared library (`jenkins/shared-library`)
3. Add credentials: AWS, kubeconfig, GitHub PAT, SonarQube token
4. Restart Jenkins

Get Jenkins API token:
- Jenkins → User → Configure → API Token → Add new token
- Paste into `backend/.env` as `JENKINS_API_TOKEN`

---

## Step 9 — Set Up SonarQube

On your SonarQube server (can be same EC2 or separate):

```bash
chmod +x scripts/setup/setup-sonarqube.sh
./scripts/setup/setup-sonarqube.sh
```

Then:
1. Login at `http://SONAR_HOST:9000` with `admin/admin`
2. Change password immediately
3. Generate token: Administration → Security → Tokens
4. Paste token into `backend/.env` as `SONAR_TOKEN`

---

## Step 10 — Get Grafana API Key

Grafana is deployed by Terraform inside EKS. Get its LoadBalancer URL:

```bash
kubectl get svc -n monitoring kube-prometheus-stack-grafana
# Copy the EXTERNAL-IP
```

Then:
1. Login at `http://GRAFANA_LB_IP` (admin / DevOpsUnify2024!)
2. Go to Administration → Service accounts → Add service account
3. Create token → paste into `backend/.env` as `GRAFANA_API_KEY`

---

## Step 11 — Start Production Backend

Update `backend/.env` with all AWS, Jenkins, SonarQube, Grafana values, then:

```bash
cd backend
npm install
npm start
```

Or deploy to EKS:

```bash
export ECR_REGISTRY=$(terraform -chdir=terraform/environments/dev output -raw ecr_registry)
chmod +x scripts/setup/deploy-platform.sh
./scripts/setup/deploy-platform.sh ap-south-1 $ECR_REGISTRY
```

---

## Step 12 — Using the Platform

1. Open http://localhost:5173 (or your frontend URL)
2. Click **Continue with GitHub** — authorize the OAuth app
3. Click **New Project** → paste a GitHub repo URL → **Analyse**
4. Review the detected project type, port, build tool
5. Click **Create Pipeline** — this:
   - Registers a GitHub webhook on your repo
   - Creates a Jenkins job with the auto-generated Jenkinsfile
   - Creates a Grafana dashboard
6. Push any commit to the repo — the webhook fires → Jenkins builds → deploys to EKS
7. Watch live build logs in the **Build** view
8. Open **Monitoring** to see the Grafana dashboard

---

## Troubleshooting

### Jenkins job not triggering on push
- Verify the webhook in GitHub: repo → Settings → Webhooks → check delivery
- Ensure `BACKEND_URL` in `.env` is publicly accessible (use ngrok for local dev)
- Check Jenkins → Manage Jenkins → System Log for webhook events

### Terraform EKS node not joining
```bash
kubectl get nodes
aws eks describe-nodegroup --cluster-name devopsunify --nodegroup-name devopsunify-ng
```

### SonarQube quality gate blocking pipeline
- SonarQube → Project → Project Settings → Quality Gate → set to your gate
- Or change `waitForQualityGate abortPipeline: true` to `false` in Jenkinsfile temporarily

### ECR push failing
```bash
aws ecr get-login-password --region ap-south-1 | \
  docker login --username AWS --password-stdin YOUR_ECR_REGISTRY
```

### View all running services
```bash
kubectl get all -n default
kubectl get all -n monitoring
kubectl get all -n devopsunify
```

---

## Architecture Overview

```
Developer
  │  git push
  ▼
GitHub ──webhook──► DevOpsUnify Backend (Node.js/Express)
                         │
           ┌─────────────┼──────────────┐
           ▼             ▼              ▼
        Jenkins      Terraform      Grafana API
        (EC2)        (AWS SDK)      (dashboard)
           │
     ┌─────┼──────────────────┐
     ▼     ▼                  ▼
  Build  SonarQube         Trivy scan
  Test   quality gate      CVE check
     │
     ▼
  Docker build → push to ECR
     │
     ▼
  Helm deploy → EKS
     │
     ▼
  Kubernetes workload
     │
     ▼
  Prometheus scrape → Grafana dashboard
```
