#!/bin/bash
set -e

SESSION_CODE="${1:-}"

# If no session code provided, generate one from current date (e.g., JAN15)
if [ -z "$SESSION_CODE" ]; then
  SESSION_CODE=$(date +"%b%d" | tr '[:lower:]' '[:upper:]')
  echo "ℹ️  No session code provided, using today's date: $SESSION_CODE"
  echo ""
fi

echo "🔄 Restarting demo to quiz mode (Session: $SESSION_CODE)..."

kubectl patch configmap api-config \
  -n default \
  --type merge \
  -p "{\"data\":{\"DEMO_MODE\":\"quiz\",\"SESSION_CODE\":\"$SESSION_CODE\"}}"

echo "🔄 Restarting API to pick up new mode..."
kubectl rollout restart deployment/api -n default

echo "⏳ Waiting for API to be ready..."
kubectl rollout status deployment/api -n default

echo "✅ Demo restarted in quiz mode for session: $SESSION_CODE"
echo ""
echo "💡 Refresh the frontend page to see the quiz"
echo ""
echo "📋 When ready for survey (T+25min): make enable-survey SESSION=$SESSION_CODE"
echo "🎁 To pick winners (T+28min): make pick-winners SESSION=$SESSION_CODE"
