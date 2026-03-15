# DevOpsUnify — Automated DevOps Platform

A unified platform that analyses a GitHub repository, auto-generates CI/CD pipelines,
provisions AWS infrastructure via Terraform, builds and scans Docker images, deploys
to Kubernetes via Helm, and surfaces real-time Grafana dashboards — all from a single UI.

## Tech Stack

| Layer | Tools |
|---|---|
| Backend API | Node.js 20, Express, PostgreSQL, Redis |
| Frontend | React 18, Vite, TailwindCSS |
| CI/CD | Jenkins (LTS), GitHub Webhooks |
| Security | SonarQube, Trivy |
| Containers | Docker, AWS ECR |
| Orchestration | Kubernetes (EKS), Helm 3 |
| IaC | Terraform 1.7 |
| Monitoring | Prometheus, Grafana, Alertmanager |
| Cloud | AWS (EKS, ECR, EC2, RDS, S3, IAM, VPC) |

## Project Structure

```
devopsunify/
├── backend/                  # Express API server
├── frontend/                 # React dashboard
├── jenkins/                  # Jenkinsfiles + Shared Library
├── terraform/                # AWS infrastructure modules
├── helm/                     # Helm chart templates
├── kubernetes/               # Raw K8s manifests (RBAC, namespaces)
├── scripts/                  # Install & setup shell scripts
└── docs/                     # Architecture docs
```

## Quick Start

```bash
# 1. Clone and enter
git clone https://github.com/YOUR_ORG/devopsunify.git
cd devopsunify

# 2. Run the master bootstrap script (installs all tools)
chmod +x scripts/install/bootstrap.sh
./scripts/install/bootstrap.sh

# 3. Configure environment
cp backend/.env.example backend/.env
# Edit backend/.env with your values

# 4. Provision AWS infrastructure
cd terraform/environments/dev
terraform init && terraform apply

# 5. Start local dev
cd backend && npm install && npm run dev
cd frontend && npm install && npm run dev
```

See `docs/SETUP.md` for the full step-by-step guide.
