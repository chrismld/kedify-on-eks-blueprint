#!/bin/bash

echo "🔍 Getting frontend URL..."

FRONTEND_URL=$(kubectl get ingress frontend -n default -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)

if [ -z "$FRONTEND_URL" ]; then
  echo "⚠️  ALB not ready yet. Checking ingress status..."
  kubectl get ingress frontend -n default
  echo ""
  echo "Wait a few minutes for the ALB to provision, then run this script again."
  exit 1
fi

echo ""
echo "✅ Frontend is available at:"
echo "   http://$FRONTEND_URL"
echo ""
echo "📋 You can also get the URL with:"
echo "   kubectl get ingress frontend -n default"
