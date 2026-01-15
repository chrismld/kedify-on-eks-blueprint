#!/bin/bash

SESSION_CODE="${1:-}"

if [ -z "$SESSION_CODE" ]; then
  echo "❌ Error: Session code is required"
  echo ""
  echo "Usage: $0 <session-code>"
  echo ""
  echo "Example: $0 JAN15AM"
  echo ""
  echo "💡 Use a memorable code like:"
  echo "   - Date-based: JAN15AM, JAN15PM, 2025-01-15"
  echo "   - Event-based: KUBECON, AWSSUMMIT, MEETUP1"
  echo "   - Simple: SESSION1, SESSION2, SESSION3"
  exit 1
fi

echo "🔧 Setting session code to: $SESSION_CODE"

kubectl patch configmap api-config \
  -n default \
  --type merge \
  -p "{\"data\":{\"SESSION_CODE\":\"$SESSION_CODE\"}}"

echo "🔄 Restarting API to pick up new session code..."
kubectl rollout restart deployment/api -n default

echo "⏳ Waiting for API to be ready..."
kubectl rollout status deployment/api -n default

echo "✅ Session code set to: $SESSION_CODE"
echo ""
echo "💡 All new survey responses will be tagged with this session"
echo "📋 To list all sessions: ./scripts/list-sessions.sh"
