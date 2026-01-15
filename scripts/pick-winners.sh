#!/bin/bash
set -e

SESSION_CODE="${1:-}"

if [ -z "$SESSION_CODE" ]; then
  echo "❌ Error: Session code is required"
  echo ""
  echo "Usage: $0 <session-code>"
  echo ""
  echo "Example: $0 JAN15AM"
  echo ""
  echo "💡 To see available sessions, run: ./scripts/list-sessions.sh"
  exit 1
fi

echo "🎁 Drawing winners for session: $SESSION_CODE"

# Get config from Terraform
cd terraform
AWS_REGION=$(terraform output -raw region 2>/dev/null || echo "eu-west-1")
AWS_ACCOUNT=$(terraform output -raw aws_account_id 2>/dev/null || aws sts get-caller-identity --query Account --output text)
PROJECT_NAME=$(terraform output -raw project_name 2>/dev/null || echo "tube-demo")
cd ..

BUCKET="${PROJECT_NAME}-responses-${AWS_ACCOUNT}"

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

# List responses for this session
echo "🔍 Looking for survey responses in session $SESSION_CODE..."
RESPONSES=$(aws s3 ls s3://$BUCKET/$SESSION_CODE/responses/ --recursive 2>/dev/null | awk '{print $4}' | grep -v "^$" || echo "")

if [ -z "$RESPONSES" ]; then
  echo "❌ No responses found for session: $SESSION_CODE"
  echo ""
  echo "💡 Available sessions:"
  ./scripts/list-sessions.sh
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
echo "🎉 Winners for session $SESSION_CODE:"
echo "$WINNERS" | sed "s|$SESSION_CODE/responses/||g" | sed 's|.json||g'
echo ""

# Extract just the IDs for the JSON
WINNER_IDS=$(echo "$WINNERS" | sed "s|$SESSION_CODE/responses/||g" | sed 's|.json||g')

# Write winners to S3
echo "💾 Saving winners to S3..."
aws s3 cp - s3://$BUCKET/$SESSION_CODE/winners.json <<EOF
{"winners": $(echo "$WINNER_IDS" | jq -Rs 'split("\n") | map(select(length > 0))')}
EOF

echo "✅ Winners announced for session $SESSION_CODE!"
echo ""
echo "💡 Winners will see a notification on their screen automatically"
