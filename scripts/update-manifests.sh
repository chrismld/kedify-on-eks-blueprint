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

# Update API deployment
echo "📝 Updating kubernetes/api/deployment.yaml..."
sed -i.bak \
  -e "s|REGISTRY_PLACEHOLDER|${REGISTRY}|g" \
  -e "s|PROJECT_PLACEHOLDER|${PROJECT_NAME}|g" \
  -e "s|REGION_PLACEHOLDER|${AWS_REGION}|g" \
  kubernetes/api/deployment.yaml

# Update Frontend deployment
echo "📝 Updating kubernetes/frontend/deployment.yaml..."
sed -i.bak \
  -e "s|REGISTRY_PLACEHOLDER|${REGISTRY}|g" \
  -e "s|PROJECT_PLACEHOLDER|${PROJECT_NAME}|g" \
  kubernetes/frontend/deployment.yaml

# Clean up backup files
rm -f kubernetes/api/deployment.yaml.bak
rm -f kubernetes/frontend/deployment.yaml.bak

echo "✅ Manifests updated!"
echo ""
echo "💡 You can now deploy with: make deploy-apps"
