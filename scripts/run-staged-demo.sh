#!/bin/bash

# =============================================================================
# Staged Demo Load Test Runner (EKS)
# =============================================================================
# Deploys and runs a staged k6 load test on EKS to showcase KEDA + Karpenter
#
# This test accounts for ~5 minute GPU node startup time:
#
# Phase 1 (0-30s):    Light load (10 VUs) - trigger initial scale-up
# Phase 2 (30s-5m):   Steady light load (10 VUs) - wait for first nodes
# Phase 3 (5m-6m):    Ramp to medium (30 VUs) - trigger more scaling
# Phase 4 (6m-10m):   Hold medium load - wait for all nodes ready
# Phase 5 (10m-12m):  Ramp to high load (80 VUs) - full capacity test
# Phase 6 (12m-15m):  Sustained high load - demonstrate scaled system
# Phase 7 (15m-16m):  Ramp down
#
# Total duration: ~16 minutes (can extend with --extended or --full)
#
# Usage: ./run-staged-demo.sh [options]
#
# Options:
#   --extended      Run extended high load phase (10 minutes instead of 3)
#   --full          Run full demo (20 minutes sustained high load)
#   --delete        Delete existing job before starting
#   --logs          Follow the k6 job logs
# =============================================================================

set -e

SCRIPT_DIR="$(dirname "$0")"
MANIFEST_DIR="${SCRIPT_DIR}/../kubernetes"
EXTENDED=false
FULL=false
DELETE=false
LOGS=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --extended)
            EXTENDED=true
            shift
            ;;
        --full)
            FULL=true
            shift
            ;;
        --delete)
            DELETE=true
            shift
            ;;
        --logs)
            LOGS=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--extended|--full] [--delete] [--logs]"
            exit 1
            ;;
    esac
done

echo "╔════════════════════════════════════════════════════════════════════════════╗"
echo "║              Staged Demo Load Test for vLLM Autoscaling (EKS)              ║"
echo "╠════════════════════════════════════════════════════════════════════════════╣"
echo "║ This test accounts for ~5 min GPU node startup time:                       ║"
echo "║                                                                            ║"
echo "║ Phase 1 (0-30s):   Light load (10 VUs) → trigger initial scale-up          ║"
echo "║ Phase 2 (30s-5m):  Hold light load → wait for first GPU nodes              ║"
echo "║ Phase 3 (5m-6m):   Ramp to medium (30 VUs) → trigger more scaling          ║"
echo "║ Phase 4 (6m-10m):  Hold medium load → wait for all nodes ready             ║"
echo "║ Phase 5 (10m-12m): Ramp to high (80 VUs) → full capacity test              ║"
echo "║ Phase 6 (12m+):    Sustained high load → demonstrate scaled system         ║"
echo "╚════════════════════════════════════════════════════════════════════════════╝"
echo ""

# Determine mode and duration
if [[ "$FULL" == "true" ]]; then
    echo "Mode: FULL (20 min sustained high load, ~32 min total)"
    HIGH_LOAD_DURATION="20m"
elif [[ "$EXTENDED" == "true" ]]; then
    echo "Mode: EXTENDED (10 min sustained high load, ~22 min total)"
    HIGH_LOAD_DURATION="10m"
else
    echo "Mode: STANDARD (3 min sustained high load, ~16 min total)"
    HIGH_LOAD_DURATION="3m"
fi
echo ""

# Delete existing job if requested or if it exists and completed
if [[ "$DELETE" == "true" ]]; then
    echo "Deleting existing k6-staged-demo job..."
    kubectl delete job k6-staged-demo --ignore-not-found=true 2>/dev/null || true
    kubectl delete configmap k6-staged-demo-script --ignore-not-found=true 2>/dev/null || true
    sleep 2
fi

# Check if job already exists
if kubectl get job k6-staged-demo &>/dev/null; then
    JOB_STATUS=$(kubectl get job k6-staged-demo -o jsonpath='{.status.conditions[0].type}' 2>/dev/null || echo "Running")
    if [[ "$JOB_STATUS" == "Complete" ]] || [[ "$JOB_STATUS" == "Failed" ]]; then
        echo "Previous job found (status: $JOB_STATUS). Deleting..."
        kubectl delete job k6-staged-demo --ignore-not-found=true
        kubectl delete configmap k6-staged-demo-script --ignore-not-found=true 2>/dev/null || true
        sleep 2
    else
        echo "Job k6-staged-demo is already running."
        echo "Use --delete to restart, or --logs to follow output."
        if [[ "$LOGS" == "true" ]]; then
            echo ""
            echo "Following k6 logs..."
            kubectl logs -f job/k6-staged-demo
        fi
        exit 0
    fi
fi

# Create ConfigMap with the appropriate high load duration
echo "Creating k6 test ConfigMap..."

# Generate the ConfigMap with the correct duration
cat > /tmp/k6-staged-demo-configmap.yaml << EOFYAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: k6-staged-demo-script
  namespace: default
data:
  staged-demo.js: |
    import http from 'k6/http';
    import { check, sleep } from 'k6';

    // Staged Demo - accounts for ~5 min GPU node startup time
    export const options = {
      scenarios: {
        staged_demo: {
          executor: 'ramping-vus',
          startVUs: 5,
          stages: [
            // Phase 1: Light load to trigger initial scaling
            { duration: '30s', target: 10 },
            // Phase 2: Hold light load while first GPU nodes provision (~5 min)
            { duration: '4m30s', target: 10 },
            // Phase 3: Ramp to medium load to trigger more scaling
            { duration: '30s', target: 30 },
            // Phase 4: Hold medium load while remaining nodes provision (~4 min)
            { duration: '4m', target: 30 },
            // Phase 5: Ramp to high load - all pods should be ready
            { duration: '1m', target: 80 },
            // Phase 6: Sustained high load - demonstrate full capacity
            { duration: '${HIGH_LOAD_DURATION}', target: 80 },
            // Phase 7: Ramp down
            { duration: '1m', target: 0 },
          ],
          gracefulRampDown: '30s',
        },
      },
      thresholds: {
        http_req_duration: ['p(95)<20000'],  // 95% under 20s (allow for cold starts)
        http_req_failed: ['rate<0.15'],      // Allow 15% failures during scaling
      },
    };

    const prompts = [
      'Explain the concept of autoscaling in Kubernetes in one paragraph.',
      'What are the benefits of using GPU instances for machine learning?',
      'Describe how KEDA works with custom metrics.',
      'What is Karpenter and how does it help with node provisioning?',
      'Explain the difference between horizontal and vertical scaling.',
      'How do inference servers handle concurrent requests?',
      'What are the key metrics to monitor for LLM serving?',
      'Describe the architecture of a typical ML inference pipeline.',
    ];

    export default function () {
      const url = 'http://vllm-service.default.svc.cluster.local:8000/v1/completions';
      const prompt = prompts[Math.floor(Math.random() * prompts.length)];
      
      const payload = JSON.stringify({
        model: 'TheBloke/Mistral-7B-Instruct-v0.2-AWQ',
        prompt: prompt,
        max_tokens: 50,
        temperature: 0.7,
      });

      const params = {
        headers: { 'Content-Type': 'application/json' },
        timeout: '45s',
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

      // Small sleep to control request rate per VU
      sleep(0.2 + Math.random() * 0.3);
    }
EOFYAML

kubectl apply -f /tmp/k6-staged-demo-configmap.yaml

# Create the Job
echo "Creating k6 Job..."
cat << 'EOFJOB' | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: k6-staged-demo
  namespace: default
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 600
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: k6
        image: grafana/k6:latest
        command: ["k6", "run", "/scripts/staged-demo.js"]
        volumeMounts:
        - name: k6-script
          mountPath: /scripts
        resources:
          requests:
            cpu: 500m
            memory: 256Mi
          limits:
            cpu: 1000m
            memory: 512Mi
      volumes:
      - name: k6-script
        configMap:
          name: k6-staged-demo-script
EOFJOB

echo ""
echo "k6 staged demo job started!"
echo ""
echo "Watch the dashboard to see KEDA and Karpenter in action!"
echo ""
echo "To follow logs:  kubectl logs -f job/k6-staged-demo"
echo "To check status: kubectl get job k6-staged-demo"
echo ""

if [[ "$LOGS" == "true" ]]; then
    echo "Following k6 logs..."
    echo ""
    # Wait for pod to be ready
    sleep 3
    kubectl logs -f job/k6-staged-demo
fi
