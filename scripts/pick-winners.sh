#!/bin/bash
set -e

echo "🎁 Drawing winners..."

AWS_REGION="eu-west-1"
BUCKET="ai-workloads-tube-demo-responses"

# Create bucket if needed
aws s3api head-bucket --bucket $BUCKET --region $AWS_REGION 2>/dev/null || \
  aws s3 mb s3://$BUCKET --region $AWS_REGION

# List responses
RESPONSES=$(aws s3 ls s3://$BUCKET/responses/ --recursive | awk '{print $4}' | grep -v "^$")

if [ -z "$RESPONSES" ]; then
  echo "❌ No responses found!"
  exit 1
fi

# Pick 2 random
WINNERS=$(echo "$RESPONSES" | shuf -n 2)

echo "🎉 Winners:"
echo "$WINNERS"

# Write winners to S3
aws s3 cp - s3://$BUCKET/winners.json <<EOF
{"winners": $(echo "$WINNERS" | jq -Rs 'split("\n")[:-1]')}
EOF

echo "✅ Winners announced!"
