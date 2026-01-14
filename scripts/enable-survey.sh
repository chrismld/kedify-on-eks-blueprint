#!/bin/bash

echo "🎯 Switching to survey mode..."

kubectl patch configmap api-config \
  -n default \
  --type merge \
  -p '{"data":{"DEMO_MODE":"survey"}}'

echo "✅ Mode switched!"
