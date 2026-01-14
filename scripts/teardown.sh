#!/bin/bash
set -e

echo "💥 Tearing down..."

# Delete all services (removes ALBs)
kubectl delete --all svc 2>/dev/null || true

# Delete Karpenter resources
kubectl delete --all nodeclaim 2>/dev/null || true
kubectl delete --all nodepool 2>/dev/null || true

# Terraform destroy
cd terraform
terraform destroy -auto-approve

echo "✅ Cleanup complete!"
