#!/bin/bash

# Gradual load test for vLLM autoscaling
# Ramps up load over 5 minutes to allow KEDA to scale proactively

set -e

# Configuration
VLLM_URL="${VLLM_URL:-http://localhost:8000}"
DURATION_RAMP="5m"      # 5 minute ramp-up
DURATION_FULL="5m"      # 5 minutes at full load
DURATION_TOTAL="10m"    # Total test duration

# VUs (Virtual Users) configuration
VU_START=1              # Start with 1 user
VU_RAMP=20              # Ramp to 20 users over 5 min
VU_FULL=50              # Full load: 50 concurrent users

echo "==================================="
echo "Gradual Load Test for vLLM"
echo "==================================="
echo "Phase 1: Ramp up from ${VU_START} to ${VU_RAMP} VUs over ${DURATION_RAMP}"
echo "Phase 2: Full load with ${VU_FULL} VUs for ${DURATION_FULL}"
echo "Total duration: ${DURATION_TOTAL}"
echo ""
echo "This allows KEDA to scale proactively as load increases"
echo "==================================="
echo ""

# Create k6 test script
cat > /tmp/gradual-load-test.js <<'EOF'
import http from 'k6/http';
import { check, sleep } from 'k6';

export const options = {
  stages: [
    { duration: '5m', target: 20 },   // Ramp up to 20 VUs over 5 min
    { duration: '5m', target: 50 },   // Ramp up to 50 VUs over next 5 min
  ],
  thresholds: {
    http_req_duration: ['p(95)<10000'], // 95% of requests under 10s
  },
};

export default function () {
  const url = __ENV.VLLM_URL + '/v1/completions';
  
  const payload = JSON.stringify({
    model: 'TheBloke/Mistral-7B-Instruct-v0.2-AWQ',
    prompt: 'Explain the concept of autoscaling in Kubernetes.',
    max_tokens: 50,
    temperature: 0.7,
  });

  const params = {
    headers: {
      'Content-Type': 'application/json',
    },
    timeout: '30s',
  };

  const res = http.post(url, payload, params);
  
  check(res, {
    'status is 200': (r) => r.status === 200,
    'has completion': (r) => {
      try {
        const body = JSON.parse(r.body);
        return body.choices && body.choices.length > 0;
      } catch (e) {
        return false;
      }
    },
  });

  sleep(1); // 1 second between requests per VU
}
EOF

# Run k6 test
echo "Starting gradual load test..."
echo ""

k6 run \
  --env VLLM_URL="${VLLM_URL}" \
  --out json=/tmp/k6-results.json \
  /tmp/gradual-load-test.js

echo ""
echo "==================================="
echo "Load test completed!"
echo "Results saved to: /tmp/k6-results.json"
echo "==================================="
