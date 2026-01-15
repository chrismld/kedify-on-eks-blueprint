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
  echo ""
  echo "⚠️  This will delete ALL data for the session (questions, responses, winners)"
  exit 1
fi

# Get config from Terraform
cd terraform
AWS_REGION=$(terraform output -raw region 2>/dev/null || echo "eu-west-1")
AWS_ACCOUNT=$(terraform output -raw aws_account_id 2>/dev/null || aws sts get-caller-identity --query Account --output text)
PROJECT_NAME=$(terraform output -raw project_name 2>/dev/null || echo "tube-demo")
cd ..

RESPONSES_BUCKET="${PROJECT_NAME}-responses-${AWS_ACCOUNT}"
QUESTIONS_BUCKET="${PROJECT_NAME}-questions-${AWS_ACCOUNT}"

echo "🗑️  Clearing session: $SESSION_CODE"
echo ""
echo "⚠️  This will delete:"
echo "   - All questions from attendees"
echo "   - All survey responses"
echo "   - Winner selections"
echo ""
read -p "Are you sure? (yes/no): " confirm

if [ "$confirm" != "yes" ]; then
  echo "❌ Cancelled"
  exit 0
fi

echo ""
echo "🧹 Deleting questions..."
aws s3 rm s3://$QUESTIONS_BUCKET/$SESSION_CODE/ --recursive 2>/dev/null || echo "   No questions found"

echo "🧹 Deleting responses..."
aws s3 rm s3://$RESPONSES_BUCKET/$SESSION_CODE/ --recursive 2>/dev/null || echo "   No responses found"

echo ""
echo "✅ Session $SESSION_CODE cleared!"
echo ""
echo "💡 The session code can be reused for a new session"
