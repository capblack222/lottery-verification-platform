#!/bin/bash

AWS_REGION="us-east-1"
AWS_ACCOUNT_ID="<ENTER_ACCNT_ID>"

ECR_BASE="$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"

# Login to ECR
aws ecr get-login-password --region $AWS_REGION | \
docker login --username AWS --password-stdin $ECR_BASE

docker buildx create --use --name multiplatform-builder 2>/dev/null || \
docker buildx use multiplatform-builder 2>/dev/null || true

# -----------------------------
# verification-service
# -----------------------------

cd verification-service

docker buildx build \
  --platform linux/amd64 \
  --provenance=false \
  -t $ECR_BASE/verification-service:latest \
  --push .

cd ..

# -----------------------------
# claims-service
# -----------------------------

cd claims-service

docker buildx build \
  --platform linux/amd64 \
  --provenance=false \
  -t $ECR_BASE/claims-service:latest \
  --push .

cd ..

echo "✅ Both images pushed to ECR"