#!/bin/bash

SESSION_CODE="${1:-DEFAULT}"

echo "🎯 Switching to survey mode (Session: $SESSION_CODE)..."

kubectl patch configmap api-config \
  -n default \
  --type merge \
  -p "{\"data\":{\"DEMO_MODE\":\"survey\",\"SESSION_CODE\":\"$SESSION_CODE\"}}"

echo "🔄 Restarting API to pick up new mode..."
kubectl rollout restart deployment/api -n default

echo "⏳ Waiting for API to be ready..."
kubectl rollout status deployment/api -n default

echo "✅ Survey mode enabled for session: $SESSION_CODE"
echo ""
echo "💡 Refresh the frontend page to see the survey"
echo ""
echo "📋 To list all sessions later: ./scripts/list-sessions.sh"
echo "🎁 To pick winners: ./scripts/pick-winners.sh $SESSION_CODE"
