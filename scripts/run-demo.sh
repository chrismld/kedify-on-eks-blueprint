#!/bin/bash
set -e

echo "🚇 Starting Tube Demo..."

# Get the ALB URL
echo "🔍 Getting frontend URL..."
FRONTEND_URL=""
for i in {1..30}; do
  FRONTEND_URL=$(kubectl get ingress frontend -n default -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
  if [ -n "$FRONTEND_URL" ]; then
    break
  fi
  echo "Waiting for ALB to be provisioned... ($i/30)"
  sleep 10
done

if [ -z "$FRONTEND_URL" ]; then
  echo "⚠️  Warning: Could not get ALB URL. Check ingress status with: kubectl get ingress frontend"
  API_URL="http://localhost:8000"
else
  echo "✅ Frontend URL: http://$FRONTEND_URL"
  API_URL="http://$FRONTEND_URL"
fi

# Port-forward API for local access (for dashboard and load gen)
echo "🔌 Setting up port-forward to API..."
kubectl port-forward -n default svc/api 8000:8000 &
API_PF_PID=$!
sleep 3

# Port-forward to OTEL scaler metrics
echo "🔌 Setting up port-forward to OTEL scaler..."
kubectl port-forward -n keda svc/keda-otel-scaler 8080:8080 &
OTEL_PF_PID=$!
sleep 2

# Start amplified load generator
echo "📊 Starting amplified load generator..."
API_URL="http://localhost:8000" MULTIPLIER=50 k6 run --quiet scripts/amplified-load-gen.js &
K6_PID=$!

# Give everything a moment to start
sleep 3

echo ""
echo "✅ Demo started!"
echo ""
if [ -n "$FRONTEND_URL" ]; then
  echo "🌐 Frontend: http://$FRONTEND_URL"
  echo "📱 Show QR code for this URL to your audience!"
fi
echo "📊 OTEL Scaler Metrics: http://localhost:8080/metrics"
echo ""
echo "🎬 Starting terminal dashboard..."
echo "   (Press Ctrl+C to stop everything)"
echo ""
sleep 2

# Start the dashboard (this will run in foreground)
bash scripts/dashboard.sh

# Cleanup on exit
trap 'kill $K6_PID $API_PF_PID $OTEL_PF_PID 2>/dev/null' EXIT
