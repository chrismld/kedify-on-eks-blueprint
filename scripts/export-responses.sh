#!/bin/bash
set -e

SESSION_CODE="${1:-}"
OUTPUT_DIR="${2:-./survey-responses}"

# Use defaults
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

echo "📊 Exporting Survey Responses"
echo "=============================="
echo ""

# If no session code provided, list all sessions
if [ -z "$SESSION_CODE" ]; then
  echo "Available sessions in bucket: $BUCKET"
  echo ""
  
  # List all session prefixes
  SESSIONS=$(aws s3 ls s3://$BUCKET/ --region $AWS_REGION 2>/dev/null | awk '{print $2}' | sed 's|/||g' | grep -v "^$" || echo "")
  
  if [ -z "$SESSIONS" ]; then
    echo "❌ No sessions found"
    exit 0
  fi
  
  echo "Session Code    | Responses | Winners | Export Command"
  echo "----------------|-----------|---------|------------------------------------------"
  
  while IFS= read -r session; do
    # Count responses
    RESP_COUNT=$(aws s3 ls s3://$BUCKET/$session/responses/ --region $AWS_REGION 2>/dev/null | wc -l | tr -d ' ')
    
    # Check for winners
    if aws s3api head-object --bucket $BUCKET --key "$session/winners.json" --region $AWS_REGION &>/dev/null; then
      WINNER_STATUS="✅ Yes"
    else
      WINNER_STATUS="⏳ No"
    fi
    
    printf "%-15s | %-9s | %-7s | ./scripts/export-responses.sh %s\n" "$session" "$RESP_COUNT" "$WINNER_STATUS" "$session"
  done <<< "$SESSIONS"
  
  echo ""
  echo "💡 Usage: $0 <session-code> [output-directory]"
  echo "   Example: $0 JAN15 ./my-responses"
  exit 0
fi

# Export specific session
echo "📦 Exporting session: $SESSION_CODE"
echo "🌍 Region: $AWS_REGION"
echo "📁 Output directory: $OUTPUT_DIR"
echo ""

# Create output directory
mkdir -p "$OUTPUT_DIR/$SESSION_CODE"

# Download all responses
echo "⬇️  Downloading responses..."
aws s3 sync s3://$BUCKET/$SESSION_CODE/ "$OUTPUT_DIR/$SESSION_CODE/" --region $AWS_REGION --quiet

# Count files
RESPONSE_COUNT=$(find "$OUTPUT_DIR/$SESSION_CODE/responses" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')

echo "✅ Exported $RESPONSE_COUNT responses to: $OUTPUT_DIR/$SESSION_CODE/"
echo ""

# Show summary
if [ -f "$OUTPUT_DIR/$SESSION_CODE/winners.json" ]; then
  echo "🎁 Winners file: $OUTPUT_DIR/$SESSION_CODE/winners.json"
  WINNERS=$(cat "$OUTPUT_DIR/$SESSION_CODE/winners.json" | jq -r '.winners[]' 2>/dev/null || echo "")
  if [ -n "$WINNERS" ]; then
    echo "   Winners:"
    echo "$WINNERS" | while read -r winner; do
      echo "   - $winner"
    done
  fi
  echo ""
fi

echo "📊 Response files: $OUTPUT_DIR/$SESSION_CODE/responses/"
echo ""
echo "💡 To analyze responses, you can:"
echo "   - Open JSON files in any text editor"
echo "   - Use jq to query: cat $OUTPUT_DIR/$SESSION_CODE/responses/*.json | jq '.'"
echo "   - Import into spreadsheet tools"
echo ""
echo "🗑️  Note: These files are safe - teardown does NOT delete S3 buckets"
