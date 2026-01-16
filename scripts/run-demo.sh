#!/bin/bash
set -e

# Cleanup on exit
cleanup() {
  echo ""
  echo "🛑 Stopping demo..."
  kill $K6_PID $API_PF_PID $OTEL_PF_PID 2>/dev/null || true
  exit 0
}
trap cleanup INT TERM

echo "🚇 Starting Tube Demo..."

# Load config if exists
if [ -f .demo-config ]; then
  source .demo-config
fi

# Get the frontend URL
echo "🔍 Getting frontend URL..."
if [ -n "$FRONTEND_URL" ]; then
  echo "✅ Using configured URL: $FRONTEND_URL"
else
  # Fall back to ALB URL
  FRONTEND_URL=""
  for i in {1..30}; do
    ALB_HOST=$(kubectl get ingress frontend -n default -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    if [ -n "$ALB_HOST" ]; then
      FRONTEND_URL="http://$ALB_HOST"
      break
    fi
    echo "Waiting for ALB to be provisioned... ($i/30)"
    sleep 10
  done
  
  if [ -z "$FRONTEND_URL" ]; then
    echo "⚠️  Warning: Could not get ALB URL. Check ingress status with: kubectl get ingress frontend"
    echo "💡 Tip: Set FRONTEND_URL in .demo-config if using CloudFront"
  else
    echo "✅ Frontend URL: $FRONTEND_URL"
  fi
fi

# Port-forward API for local access (for dashboard and load gen)
echo "🔌 Setting up port-forward to API..."
kubectl port-forward -n default svc/api 8000:8000 &
API_PF_PID=$!
sleep 3

# Port-forward to OTEL scaler metrics (if KEDA is installed)
if kubectl get namespace keda &>/dev/null && kubectl get svc -n keda keda-otel-scaler &>/dev/null; then
  echo "🔌 Setting up port-forward to OTEL scaler..."
  kubectl port-forward -n keda svc/keda-otel-scaler 8080:8080 &
  OTEL_PF_PID=$!
  sleep 2
  KEDA_ENABLED=true
else
  echo "⚠️  KEDA not installed - scaling disabled"
  echo "💡 See SETUP-NOTES.md to enable KEDA/Kedify"
  OTEL_PF_PID=""
  KEDA_ENABLED=false
fi

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
  echo "🌐 Frontend: $FRONTEND_URL"
  echo "📱 Show QR code for this URL to your audience!"
fi
if [ "$KEDA_ENABLED" = true ]; then
  echo "📊 OTEL Scaler Metrics: http://localhost:8080/metrics"
else
  echo "⚠️  Scaling disabled (KEDA not installed)"
fi
echo ""
echo "🎬 Starting terminal dashboard..."
echo "   (Press Ctrl+C to stop everything)"
echo ""
sleep 2

# Start the dashboard (this will run in foreground)
bash scripts/dashboard.sh
