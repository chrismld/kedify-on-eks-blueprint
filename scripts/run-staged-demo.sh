#!/bin/bash

# =============================================================================
# Staged Demo Load Test Runner (EKS)
# =============================================================================
# Deploys and runs a staged k6 load test on EKS to showcase KEDA + Karpenter
#
# Usage: ./run-staged-demo.sh [options]
#
# Options:
#   --extended      Run extended Stage 3 (10 minutes instead of 2)
#   --full          Run full demo (20 minutes sustained load)
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
echo "║ This test demonstrates KEDA + Karpenter scaling in 3 stages:               ║"
echo "║                                                                            ║"
echo "║ Stage 1 (0-1m):   Light load → triggers first scale-up (1→2 pods)          ║"
echo "║ Wait (1-6m):      Karpenter provisions first GPU node (~4-5 min)           ║"
echo "║ Stage 2 (6-7m):   Medium load → triggers aggressive scale-up (2→10 pods)   ║"
echo "║ Wait (7-12m):     Karpenter provisions remaining nodes (~4-5 min)          ║"
echo "║ Stage 3 (12-14m): Full sustained load                                      ║"
echo "╚════════════════════════════════════════════════════════════════════════════╝"
echo ""

# Determine mode and duration
if [[ "$FULL" == "true" ]]; then
    echo "Mode: FULL (20 min sustained load, ~32 min total)"
    STAGE3_DURATION="20m"
elif [[ "$EXTENDED" == "true" ]]; then
    echo "Mode: EXTENDED (10 min sustained load, ~22 min total)"
    STAGE3_DURATION="10m"
else
    echo "Mode: STANDARD (2 min sustained load, ~14 min total)"
    STAGE3_DURATION="2m"
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

# Create ConfigMap with the appropriate stage 3 duration
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

    export const options = {
      scenarios: {
        staged_demo: {
          executor: 'ramping-vus',
          startVUs: 0,
          stages: [
            { duration: '30s', target: 5 },
            { duration: '30s', target: 5 },
            { duration: '5m', target: 2 },
            { duration: '30s', target: 30 },
            { duration: '30s', target: 30 },
            { duration: '5m', target: 5 },
            { duration: '30s', target: 50 },
            { duration: '${STAGE3_DURATION}', target: 50 },
            { duration: '30s', target: 0 },
          ],
          gracefulRampDown: '30s',
        },
      },
      thresholds: {
        http_req_duration: ['p(95)<30000'],
        http_req_failed: ['rate<0.3'],
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
        timeout: '60s',
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

      sleep(0.5 + Math.random() * 0.5);
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
  ttlSecondsAfterFinished: 300
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
