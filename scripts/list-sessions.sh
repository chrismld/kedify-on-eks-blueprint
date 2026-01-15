#!/bin/bash
set -e

# Get config from Terraform
cd terraform
AWS_REGION=$(terraform output -raw region 2>/dev/null || echo "eu-west-1")
AWS_ACCOUNT=$(terraform output -raw aws_account_id 2>/dev/null || aws sts get-caller-identity --query Account --output text)
PROJECT_NAME=$(terraform output -raw project_name 2>/dev/null || echo "tube-demo")
cd ..

BUCKET="${PROJECT_NAME}-responses-${AWS_ACCOUNT}"

echo "📋 Available Sessions"
echo "===================="
echo ""

# Check if bucket exists
if ! aws s3api head-bucket --bucket $BUCKET --region $AWS_REGION 2>/dev/null; then
  echo "❌ No sessions found (bucket doesn't exist yet)"
  echo ""
  echo "💡 Sessions will appear after you run your first demo with a session code"
  exit 0
fi

# List all session prefixes
SESSIONS=$(aws s3 ls s3://$BUCKET/ 2>/dev/null | awk '{print $2}' | sed 's|/||g' | grep -v "^$" || echo "")

if [ -z "$SESSIONS" ]; then
  echo "❌ No sessions found"
  echo ""
  echo "💡 Set a session code when starting your demo:"
  echo "   kubectl patch configmap api-config -n default --type merge -p '{\"data\":{\"SESSION_CODE\":\"JAN15AM\"}}'"
  exit 0
fi

echo "Session Code    | Responses | Winners"
echo "----------------|-----------|--------"

while IFS= read -r session; do
  # Count responses
  RESP_COUNT=$(aws s3 ls s3://$BUCKET/$session/responses/ 2>/dev/null | wc -l | tr -d ' ')
  
  # Check for winners
  if aws s3api head-object --bucket $BUCKET --key "$session/winners.json" &>/dev/null; then
    WINNER_STATUS="✅ Picked"
  else
    WINNER_STATUS="⏳ Pending"
  fi
  
  printf "%-15s | %-9s | %s\n" "$session" "$RESP_COUNT" "$WINNER_STATUS"
done <<< "$SESSIONS"

echo ""
echo "💡 To pick winners for a session:"
echo "   ./scripts/pick-winners.sh <session-code>"
echo ""
echo "Example: ./scripts/pick-winners.sh JAN15AM"
