#!/bin/bash
set -e

echo "🔄 Invalidating CloudFront cache..."

# Get CloudFront distribution ID from Terraform
cd terraform
DISTRIBUTION_ID=$(terraform output -raw cloudfront_distribution_id 2>/dev/null)
cd ..

if [ -z "$DISTRIBUTION_ID" ]; then
  echo "❌ Error: Could not get CloudFront distribution ID"
  echo "   Make sure CloudFront is deployed: make setup-cloudfront"
  exit 1
fi

echo "📋 Distribution ID: $DISTRIBUTION_ID"

# Create invalidation for all paths
INVALIDATION_ID=$(aws cloudfront create-invalidation \
  --distribution-id $DISTRIBUTION_ID \
  --paths "/*" \
  --query 'Invalidation.Id' \
  --output text)

echo "✅ Invalidation created: $INVALIDATION_ID"
echo ""
echo "⏳ Cache invalidation in progress..."
echo "   This usually takes 1-2 minutes"
echo ""
echo "💡 You can check status with:"
echo "   aws cloudfront get-invalidation --distribution-id $DISTRIBUTION_ID --id $INVALIDATION_ID"
echo ""
echo "🌐 Try accessing your CloudFront URL in a few minutes"
