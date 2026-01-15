#!/bin/bash
set -e

echo "🎁 Drawing winners..."

AWS_REGION="eu-west-1"
AWS_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
BUCKET="ai-workloads-tube-demo-responses-${AWS_ACCOUNT}"

echo "📦 Using bucket: $BUCKET"

# Create bucket if needed
if aws s3api head-bucket --bucket $BUCKET --region $AWS_REGION 2>/dev/null; then
  echo "✅ Bucket already exists"
else
  echo "🔨 Creating bucket..."
  aws s3 mb s3://$BUCKET --region $AWS_REGION
  
  # Block public access
  aws s3api put-public-access-block \
    --bucket $BUCKET \
    --public-access-block-configuration \
      "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
  
  echo "✅ Bucket created and secured"
fi

# List responses
echo "🔍 Looking for survey responses..."
RESPONSES=$(aws s3 ls s3://$BUCKET/responses/ --recursive 2>/dev/null | awk '{print $4}' | grep -v "^$" || echo "")

if [ -z "$RESPONSES" ]; then
  echo "❌ No responses found!"
  echo "   Make sure people have submitted surveys first"
  exit 1
fi

RESPONSE_COUNT=$(echo "$RESPONSES" | wc -l | tr -d ' ')
echo "📊 Found $RESPONSE_COUNT survey responses"

# Pick 2 random (or all if less than 2)
if [ "$RESPONSE_COUNT" -lt 2 ]; then
  echo "⚠️  Only $RESPONSE_COUNT response(s) found, selecting all"
  WINNERS="$RESPONSES"
else
  WINNERS=$(echo "$RESPONSES" | shuf -n 2)
fi

echo ""
echo "🎉 Winners:"
echo "$WINNERS" | sed 's|responses/||g' | sed 's|.json||g'
echo ""

# Extract just the IDs for the JSON
WINNER_IDS=$(echo "$WINNERS" | sed 's|responses/||g' | sed 's|.json||g')

# Write winners to S3
echo "💾 Saving winners to S3..."
aws s3 cp - s3://$BUCKET/winners.json <<EOF
{"winners": $(echo "$WINNER_IDS" | jq -Rs 'split("\n") | map(select(length > 0))')}
EOF

echo "✅ Winners announced!"
echo ""
echo "💡 Winners will see a notification on their screen automatically"
