#!/bin/bash
# Run k6 load test inside the cluster
# Usage: ./scripts/run-load-test.sh [--watch] [--cleanup-only]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

cleanup() {
    echo -e "${YELLOW}Cleaning up previous k6 job...${NC}"
    kubectl delete job k6-load-test --ignore-not-found=true -n default 2>/dev/null || true
    # Wait for pod to be fully removed
    while kubectl get pods -n default -l job-name=k6-load-test 2>/dev/null | grep -q k6; do
        echo "Waiting for old k6 pod to terminate..."
        sleep 2
    done
    echo -e "${GREEN}Cleanup complete${NC}"
}

run_test() {
    echo -e "${GREEN}Applying k6 ConfigMap and Job...${NC}"
    kubectl apply -f "$PROJECT_ROOT/kubernetes/k6-load-test.yaml"
    
    echo -e "${YELLOW}Waiting for k6 pod to start...${NC}"
    kubectl wait --for=condition=Ready pod -l job-name=k6-load-test -n default --timeout=60s 2>/dev/null || true
    
    echo -e "${GREEN}k6 load test started!${NC}"
    echo ""
}

watch_test() {
    echo -e "${YELLOW}Streaming k6 logs (Ctrl+C to stop watching, test continues)...${NC}"
    echo ""
    kubectl logs -f job/k6-load-test -n default 2>/dev/null || true
}

show_status() {
    echo ""
    echo -e "${GREEN}=== Current Status ===${NC}"
    echo ""
    echo "k6 Job:"
    kubectl get job k6-load-test -n default 2>/dev/null || echo "  No k6 job running"
    echo ""
    echo "vLLM Pods:"
    kubectl get pods -l app=vllm -n default 2>/dev/null
    echo ""
    echo "GPU Nodes:"
    kubectl get nodes -l intent=gpu-inference 2>/dev/null || echo "  No GPU nodes"
    echo ""
}

# Parse arguments
WATCH=false
CLEANUP_ONLY=false

for arg in "$@"; do
    case $arg in
        --watch|-w)
            WATCH=true
            ;;
        --cleanup-only|-c)
            CLEANUP_ONLY=true
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --watch, -w        Stream k6 logs after starting"
            echo "  --cleanup-only, -c Only cleanup, don't start new test"
            echo "  --help, -h         Show this help"
            echo ""
            echo "Examples:"
            echo "  $0                 # Cleanup and run new test"
            echo "  $0 --watch         # Cleanup, run, and stream logs"
            echo "  $0 --cleanup-only  # Just cleanup old job"
            exit 0
            ;;
    esac
done

# Always cleanup first
cleanup

if [ "$CLEANUP_ONLY" = true ]; then
    echo -e "${GREEN}Done!${NC}"
    exit 0
fi

# Run the test
run_test

# Show status
show_status

if [ "$WATCH" = true ]; then
    watch_test
else
    echo -e "${YELLOW}Tip: Run with --watch to stream logs, or use:${NC}"
    echo "  kubectl logs -f job/k6-load-test"
    echo ""
    echo -e "${YELLOW}To check scaling:${NC}"
    echo "  kubectl get pods -l app=vllm -w"
    echo "  kubectl get nodes -l intent=gpu-inference -w"
fi
