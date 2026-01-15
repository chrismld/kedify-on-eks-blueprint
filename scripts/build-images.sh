#!/bin/bash
set -e

echo "🔍 Getting configuration from Terraform..."
cd terraform

AWS_ACCOUNT_ID=$(terraform output -raw aws_account_id 2>/dev/null || aws sts get-caller-identity --query Account --output text)
AWS_REGION=$(terraform output -raw region 2>/dev/null || echo "eu-west-1")
PROJECT_NAME=$(terraform output -raw project_name 2>/dev/null || echo "tube-demo")

cd ..

REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

echo "📦 Configuration:"
echo "   Account: ${AWS_ACCOUNT_ID}"
echo "   Region: ${AWS_REGION}"
echo "   Project: ${PROJECT_NAME}"
echo "   Registry: ${REGISTRY}"
echo ""

# Login to ECR
aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $REGISTRY

# Ensure we're using a buildx builder that supports multi-platform
if ! docker buildx inspect multiarch-builder &>/dev/null; then
  echo "Creating multiarch builder..."
  docker buildx create --name multiarch-builder --use
else
  echo "Using existing multiarch-builder..."
  docker buildx use multiarch-builder
fi

# Build and push API
echo "📦 Building API..."
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t $REGISTRY/${PROJECT_NAME}/api:latest \
  --push \
  app/api/

# Build and push Frontend
echo "📦 Building Frontend..."
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t $REGISTRY/${PROJECT_NAME}/frontend:latest \
  --push \
  app/frontend/

echo "✅ Images built and pushed!"
echo ""
echo "💡 Next step: Update Kubernetes manifests with these image URLs"
echo "   Run: ./scripts/update-manifests.sh"
