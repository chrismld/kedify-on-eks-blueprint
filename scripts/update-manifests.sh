#!/bin/bash
set -e

echo "🔧 Updating Kubernetes manifests..."

# Get values from AWS CLI / environment
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION=${AWS_REGION:-$(aws configure get region)}
PROJECT_NAME=${PROJECT_NAME:-"kedify-on-eks-blueprint"}

# Get EFS filesystem ID by name tag
EFS_FILESYSTEM_ID=$(aws efs describe-file-systems \
  --query "FileSystems[?Tags[?Key=='Name' && contains(Value, '${PROJECT_NAME}')]].FileSystemId | [0]" \
  --output text 2>/dev/null || echo "")
[ "$EFS_FILESYSTEM_ID" = "None" ] && EFS_FILESYSTEM_ID=""

REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

echo "📦 Configuration:"
echo "   Account: ${AWS_ACCOUNT_ID}"
echo "   Region: ${AWS_REGION}"
echo "   Project: ${PROJECT_NAME}"
echo "   Registry: ${REGISTRY}"
if [ -n "$EFS_FILESYSTEM_ID" ]; then
  echo "   EFS: ${EFS_FILESYSTEM_ID}"
else
  echo "   EFS: (not found - kubernetes/efs/pv.yaml will not be generated)"
fi
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

# Update EFS PV from template
if [ -n "$EFS_FILESYSTEM_ID" ]; then
  echo "📝 Generating kubernetes/efs/pv.yaml from template..."
  sed "s|EFS_FILESYSTEM_ID|${EFS_FILESYSTEM_ID}|g" \
    kubernetes/efs/pv.yaml.template > kubernetes/efs/pv.yaml
fi

echo ""
echo "✅ Manifests generated!"
echo ""
echo "💡 You can now deploy with: make deploy-apps"
