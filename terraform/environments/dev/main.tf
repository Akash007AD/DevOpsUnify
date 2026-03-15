terraform {
  required_version = ">= 1.7"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
  }

  backend "s3" {
    # Configure via -backend-config or environment variables
    # terraform init -backend-config="bucket=devopsunify-tfstate" \
    #                -backend-config="key=dev/terraform.tfstate" \
    #                -backend-config="region=ap-south-1"
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Project     = var.project_name
      Environment = "dev"
      ManagedBy   = "devopsunify-terraform"
    }
  }
}

# ── Variables ─────────────────────────────────────────────────────────────────
variable "project_name" { type = string }
variable "aws_region"   { type = string; default = "ap-south-1" }
variable "project_id"   { type = string }

# ── Networking ────────────────────────────────────────────────────────────────
module "networking" {
  source       = "../../modules/networking"
  project_name = var.project_name
  aws_region   = var.aws_region
}

# ── ECR ───────────────────────────────────────────────────────────────────────
module "ecr" {
  source       = "../../modules/ecr"
  project_name = var.project_name
}

# ── EKS ───────────────────────────────────────────────────────────────────────
module "eks" {
  source          = "../../modules/eks"
  project_name    = var.project_name
  aws_region      = var.aws_region
  vpc_id          = module.networking.vpc_id
  private_subnets = module.networking.private_subnets
}

# ── Helm provider (needs EKS outputs) ────────────────────────────────────────
provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_ca)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
      command     = "aws"
    }
  }
}

# ── Monitoring (kube-prometheus-stack) ────────────────────────────────────────
module "monitoring" {
  source       = "../../modules/monitoring"
  project_name = var.project_name
  depends_on   = [module.eks]
}

# ── S3 bucket for TF state (bootstrap only) ──────────────────────────────────
resource "aws_s3_bucket" "tfstate" {
  bucket        = "devopsunify-tfstate-${var.project_id}"
  force_destroy = false
  lifecycle { prevent_destroy = true }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_dynamodb_table" "tflock" {
  name         = "devopsunify-tflock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"
  attribute {
    name = "LockID"
    type = "S"
  }
}

# ── Outputs ───────────────────────────────────────────────────────────────────
output "vpc_id"              { value = module.networking.vpc_id }
output "ecr_repository_url" { value = module.ecr.ecr_repository_url }
output "cluster_name"        { value = module.eks.cluster_name }
output "cluster_endpoint"    { value = module.eks.cluster_endpoint }
