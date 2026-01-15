#!/bin/bash
set -e

SESSION_CODE="${1:-}"

# If no session code provided, generate one from current date (e.g., JAN15)
if [ -z "$SESSION_CODE" ]; then
  SESSION_CODE=$(date +"%b%d" | tr '[:lower:]' '[:upper:]')
  echo "ℹ️  No session code provided, using today's date: $SESSION_CODE"
  echo ""
fi

echo "🎁 Drawing winners for session: $SESSION_CODE"

# Use defaults - simpler and more reliable
AWS_REGION="eu-west-1"
PROJECT_NAME="ai-workloads-tube-demo"

# Get AWS account ID from AWS CLI
AWS_ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")
if [ -z "$AWS_ACCOUNT" ]; then
  echo "❌ Error: Could not determine AWS account ID"
  echo "   Make sure AWS CLI is configured: aws configure"
  exit 1
fi

BUCKET="${PROJECT_NAME}-responses-${AWS_ACCOUNT}"

echo "📦 Using bucket: $BUCKET"
echo "🌍 Region: $AWS_REGION"
echo ""

# Check if bucket exists (it should have been created by the API)
if ! aws s3api head-bucket --bucket $BUCKET --region $AWS_REGION 2>/dev/null; then
  echo "❌ Error: Bucket $BUCKET does not exist"
  echo "   The API should have created this bucket automatically."
  echo "   Make sure the API has been deployed and has received at least one survey response."
  exit 1
fi

echo "✅ Bucket exists"

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
WINNERS_JSON=$(echo "$WINNER_IDS" | jq -Rs 'split("\n") | map(select(length > 0))')
echo "   Winners JSON: {\"winners\": $WINNERS_JSON}"

aws s3 cp - s3://$BUCKET/$SESSION_CODE/winners.json <<EOF
{"winners": $WINNERS_JSON}
EOF

echo "✅ Winners announced for session $SESSION_CODE!"
echo ""
echo "💡 Winners will see a notification on their screen automatically"
echo "   (Frontend polls /api/survey/winners every 2 seconds)"
