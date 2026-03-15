terraform {
  required_version = ">= 1.7"
  required_providers {
    aws        = { source = "hashicorp/aws";        version = "~> 5.0" }
    helm       = { source = "hashicorp/helm";       version = "~> 2.12" }
    kubernetes = { source = "hashicorp/kubernetes"; version = "~> 2.26" }
  }
  backend "s3" {}
}

provider "aws"        { region = var.aws_region }
provider "helm"       {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_ca)
    token                  = data.aws_eks_cluster_auth.main.token
  }
}
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_ca)
  token                  = data.aws_eks_cluster_auth.main.token
}

data "aws_eks_cluster_auth" "main" { name = module.eks.cluster_name }
data "aws_caller_identity" "current" {}

variable "aws_region"   { type = string; default = "ap-south-1" }
variable "project_name" { type = string; default = "devopsunify" }
variable "project_id"   { type = string; default = "devopsunify-prod" }
variable "db_password"  { type = string; sensitive = true }

module "networking" {
  source       = "../../modules/networking"
  project_name = "${var.project_name}-prod"
  aws_region   = var.aws_region
  vpc_cidr     = "10.1.0.0/16"
}

module "eks" {
  source             = "../../modules/eks"
  project_name       = "${var.project_name}-prod"
  vpc_id             = module.networking.vpc_id
  private_subnet_ids = module.networking.private_subnet_ids
  public_subnet_ids  = module.networking.public_subnet_ids
}

module "ecr" {
  source       = "../../modules/ecr"
  project_name = var.project_name
  repo_names   = [var.project_name]
}

module "rds" {
  source             = "../../modules/rds"
  project_name       = "${var.project_name}-prod"
  vpc_id             = module.networking.vpc_id
  private_subnet_ids = module.networking.private_subnet_ids
  db_password        = var.db_password
  instance_class     = "db.t3.small"
}

module "monitoring" {
  source       = "../../modules/monitoring"
  cluster_name = module.eks.cluster_name
  depends_on   = [module.eks]
}

output "cluster_name"       { value = module.eks.cluster_name }
output "ecr_registry"       { value = module.ecr.registry_url }
output "rds_endpoint"       { value = module.rds.rds_endpoint }
output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}
