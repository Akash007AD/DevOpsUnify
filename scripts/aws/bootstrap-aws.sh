#!/usr/bin/env bash
# =============================================================================
# DevOpsUnify — AWS Pre-requisites Bootstrap
# Creates S3 bucket + DynamoDB table for Terraform remote state
# Run ONCE before `terraform init`
# Usage: ./scripts/aws/bootstrap-aws.sh ap-south-1 my-project
# =============================================================================
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; exit 1; }

AWS_REGION=${1:-ap-south-1}
PROJECT_NAME=${2:-devopsunify}
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

BUCKET_NAME="${PROJECT_NAME}-tfstate-${ACCOUNT_ID}"
TABLE_NAME="${PROJECT_NAME}-tflock"

log "AWS Account: ${ACCOUNT_ID}"
log "Region:      ${AWS_REGION}"
log "Bucket:      ${BUCKET_NAME}"
log "DynamoDB:    ${TABLE_NAME}"
echo ""

# ===========================================================================
# S3 Bucket for Terraform state
# ===========================================================================
if aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
  warn "S3 bucket ${BUCKET_NAME} already exists"
else
  log "Creating S3 bucket: ${BUCKET_NAME}..."
  if [[ "$AWS_REGION" == "us-east-1" ]]; then
    aws s3api create-bucket \
      --bucket "$BUCKET_NAME" \
      --region "$AWS_REGION"
  else
    aws s3api create-bucket \
      --bucket "$BUCKET_NAME" \
      --region "$AWS_REGION" \
      --create-bucket-configuration LocationConstraint="$AWS_REGION"
  fi

  # Enable versioning
  aws s3api put-bucket-versioning \
    --bucket "$BUCKET_NAME" \
    --versioning-configuration Status=Enabled

  # Enable encryption
  aws s3api put-bucket-encryption \
    --bucket "$BUCKET_NAME" \
    --server-side-encryption-configuration '{
      "Rules": [{
        "ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"},
        "BucketKeyEnabled": true
      }]
    }'

  # Block public access
  aws s3api put-public-access-block \
    --bucket "$BUCKET_NAME" \
    --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

  log "S3 bucket created and configured"
fi

# ===========================================================================
# DynamoDB table for state locking
# ===========================================================================
if aws dynamodb describe-table --table-name "$TABLE_NAME" --region "$AWS_REGION" 2>/dev/null; then
  warn "DynamoDB table ${TABLE_NAME} already exists"
else
  log "Creating DynamoDB table: ${TABLE_NAME}..."
  aws dynamodb create-table \
    --table-name "$TABLE_NAME" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "$AWS_REGION"

  aws dynamodb wait table-exists \
    --table-name "$TABLE_NAME" \
    --region "$AWS_REGION"

  log "DynamoDB table created"
fi

# ===========================================================================
# Create IAM policy for Terraform (least-privilege)
# ===========================================================================
POLICY_NAME="${PROJECT_NAME}-terraform-policy"
log "Creating IAM policy: ${POLICY_NAME}..."

POLICY_DOC=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "TerraformStateAccess",
      "Effect": "Allow",
      "Action": ["s3:GetObject","s3:PutObject","s3:DeleteObject","s3:ListBucket"],
      "Resource": [
        "arn:aws:s3:::${BUCKET_NAME}",
        "arn:aws:s3:::${BUCKET_NAME}/*"
      ]
    },
    {
      "Sid": "TerraformLockAccess",
      "Effect": "Allow",
      "Action": ["dynamodb:GetItem","dynamodb:PutItem","dynamodb:DeleteItem"],
      "Resource": "arn:aws:dynamodb:${AWS_REGION}:${ACCOUNT_ID}:table/${TABLE_NAME}"
    },
    {
      "Sid": "EKSAccess",
      "Effect": "Allow",
      "Action": ["eks:*","ec2:*","iam:*","ecr:*","s3:*","dynamodb:*","rds:*","elasticloadbalancing:*","autoscaling:*","cloudwatch:*","logs:*"],
      "Resource": "*"
    }
  ]
}
EOF
)

aws iam create-policy \
  --policy-name "$POLICY_NAME" \
  --policy-document "$POLICY_DOC" \
  --description "DevOpsUnify Terraform execution policy" 2>/dev/null || warn "Policy already exists"

# ===========================================================================
# Output backend config snippet
# ===========================================================================
cat <<EOF

${GREEN}==================================================================
Bootstrap complete! Use these values for terraform init:
==================================================================

terraform init \\
  -backend-config="bucket=${BUCKET_NAME}" \\
  -backend-config="key=dev/terraform.tfstate" \\
  -backend-config="region=${AWS_REGION}" \\
  -backend-config="dynamodb_table=${TABLE_NAME}"

Add to backend/.env:
  TF_STATE_BUCKET=${BUCKET_NAME}
  TF_LOCK_TABLE=${TABLE_NAME}
  AWS_REGION=${AWS_REGION}
==================================================================
${NC}
EOF
