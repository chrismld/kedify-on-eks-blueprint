#!/bin/bash
set -e

echo "🔧 Updating Kubernetes manifests with Terraform outputs..."

cd terraform

AWS_ACCOUNT_ID=$(terraform output -raw aws_account_id)
AWS_REGION=$(terraform output -raw region)
PROJECT_NAME=$(terraform output -raw project_name)

cd ..

REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

echo "📦 Configuration:"
echo "   Account: ${AWS_ACCOUNT_ID}"
echo "   Region: ${AWS_REGION}"
echo "   Project: ${PROJECT_NAME}"
echo "   Registry: ${REGISTRY}"
echo ""

# Update API deployment from template
echo "📝 Generating kubernetes/api/deployment.yaml from template..."
sed \
  -e "s|REGISTRY_PLACEHOLDER|${REGISTRY}|g" \
  -e "s|PROJECT_PLACEHOLDER|${PROJECT_NAME}|g" \
  -e "s|REGION_PLACEHOLDER|${AWS_REGION}|g" \
  kubernetes/api/deployment.yaml.template > kubernetes/api/deployment.yaml

# Update Frontend deployment from template
echo "📝 Generating kubernetes/frontend/deployment.yaml from template..."
sed \
  -e "s|REGISTRY_PLACEHOLDER|${REGISTRY}|g" \
  -e "s|PROJECT_PLACEHOLDER|${PROJECT_NAME}|g" \
  kubernetes/frontend/deployment.yaml.template > kubernetes/frontend/deployment.yaml

echo "✅ Manifests generated from templates!"
echo ""
echo "💡 You can now deploy with: make deploy-apps"

