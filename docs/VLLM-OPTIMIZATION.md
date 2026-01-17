# vLLM Startup Optimization Guide

## Overview

This optimization reduces vLLM pod startup time from **14 minutes to 30-60 seconds** by pre-baking the Mistral 7B model into a custom Bottlerocket AMI.

## The Problem

**Without optimization:**
- Pod startup: 14 minutes (model downloads from HuggingFace)
- Scale 1→5 replicas: 70 minutes (5× downloads)
- Every pod restart: 14 minutes (re-download)

**With optimization:**
- Pod startup: **30-60 seconds** (model pre-baked on node)
- Scale 1→5 replicas: **2-3 minutes** (no downloads)
- Pod restart: **45 seconds** (instant reuse)

## How It Works

The optimization creates an EBS snapshot with the Mistral 7B model pre-downloaded:

1. **Launch Bottlerocket instance** (standard AWS-maintained AMI) with 150GB data volume
2. **Download model** from HuggingFace to the data volume (~10-15 min)
3. **Create snapshot** of the data volume with the model
4. **Karpenter uses standard Bottlerocket AMI** + the snapshot for the data volume
5. **vLLM pods mount** `/mnt/models` and find the model already there

The snapshot ID is stored locally (`.snapshot-id`, not in git). The root volume uses the standard Bottlerocket AMI maintained by AWS.

## Implementation Steps

### For New Setups

Just run the standard setup - optimization is automatic:

```bash
make setup-infra
```

This will build the EBS snapshot with model pre-cached (~25-30 minutes extra on first run).

### For Existing Clusters

Deploy the optimization to your running cluster:

```bash
make optimize-vllm
```

This will:
1. Build EBS snapshot with Mistral 7B model pre-cached (~25-30 min)
2. Deploy optimized GPU NodeClass (uses standard Bottlerocket AMI + snapshot)
3. Restart vLLM pods to use the new nodes

Total time: ~30 minutes (automated)

### 2. Test the Optimization

```bash
# Scale to 5 replicas
kubectl scale deployment vllm --replicas=5

# Watch pods come up (should be 2-3 minutes total)
kubectl get pods -w -l app=vllm
```

## Key Changes

### Karpenter NodeClass
- Uses standard Bottlerocket AMI (AWS-maintained, stays up-to-date)
- Adds 150GB EBS data volume with snapshot containing the model
- Includes userData to mount model volume on boot
- Optimized EBS settings (3000 IOPS, 125 MB/s throughput)

### vLLM Deployment
- Removed `emptyDir` volume (no longer needed)
- Uses `hostPath` to mount pre-populated model from node
- Added resource requests (memory: 16Gi, cpu: 4)
- Environment variables point to `/mnt/models/hf-cache`
- Clean, simple configuration for demo purposes

## Cost Analysis

- Snapshot storage: ~$6/month for 150GB
- **Savings:** Hours of waiting + reduced data transfer costs

Break-even: After 2-3 days of normal scaling operations

## Demo Timeline

Perfect for KCD talk:

```
0:00 - "Watch us scale 5 GPU nodes with vLLM inference"
0:00 - kubectl scale deployment vllm --replicas=5
0:30 - First 2 pods running
1:30 - All 5 pods ready, serving requests
1:45 - "Model was pre-baked into the AMI. No downloads needed."
```

## Troubleshooting

### Pods stuck in Pending
- Check if Karpenter provisioned nodes: `kubectl get nodes`
- Verify snapshot ID is correct in NodeClass
- Check node logs: `kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter`

### Pods crash on startup
- Verify model volume is mounted: `kubectl exec -it <pod> -- ls -la /mnt/models`
- Check vLLM logs: `kubectl logs <pod>`
- Ensure snapshot ID is correct in NodeClass

### Slow startup despite optimization
- Verify snapshot is attached (check node EBS volumes)
- Ensure EBS volume is attached and mounted
- Check if vLLM image is cached: SSH to node and check containerd images

## References

- Full optimization guide: `optimization-final-state.md`
- AMI build scripts: `scripts/ami-build/`
- Karpenter docs: https://karpenter.sh/
- vLLM docs: https://docs.vllm.ai/
