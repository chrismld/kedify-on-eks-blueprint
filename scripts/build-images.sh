#!/bin/bash
set -e

echo "🔨 Building multi-arch images..."

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION="eu-west-1"
REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

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
  -t $REGISTRY/ai-workloads-tube-demo/api:latest \
  --push \
  app/api/

# Build and push Frontend
echo "📦 Building Frontend..."
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t $REGISTRY/ai-workloads-tube-demo/frontend:latest \
  --push \
  app/frontend/

echo "✅ Images built and pushed!"
