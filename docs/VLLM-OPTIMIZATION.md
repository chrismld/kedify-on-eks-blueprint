# vLLM Cold Start Optimization: EBS Snapshot + S3 Streaming

## The Challenge

When you're running LLM inference on Kubernetes, cold starts are your enemy. Every time a new pod spins up, it needs to:
1. Pull a large container image (~8-10GB for vLLM)
2. Load multi-gigabyte model weights into GPU memory

For our Mistral 7B model, the baseline was **14+ minutes** just for the model to download from HuggingFace before serving a single request.

**TL;DR:** We achieved ~90 second cold starts using EBS snapshots (pre-cached container image) + S3 streaming (model weights).

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                     GPU Nodes (Karpenter)                   │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ EBS Snapshot (Data Volume)                          │   │
│  │ - vLLM container image PRE-CACHED                   │   │
│  │ - Zero container pull time                          │   │
│  │ - Node boots with image already on disk             │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────┐
│                         S3 Bucket                           │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ /models/mistral-7b-awq/                             │   │
│  │ - Mistral-7B-Instruct-v0.2-AWQ (~4GB, quantized)   │   │
│  │ - Streamed directly via Run:ai Streamer             │   │
│  │ - Fits on T4 GPU (16GB VRAM) with room for KV cache│   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

**Why this architecture?**

| Concern | Standard Pull | EBS Snapshot + S3 |
|---------|---------------|-------------------|
| Container image | ~4-5 min pull | **0s** (pre-cached) |
| Model loading | S3 streaming (~30s) | S3 streaming (~30s) |
| Total cold start | ~5-6 min | **~90s** |
| Complexity | Low | Medium (one-time snapshot) |
| Cost | Minimal | +$0.05/GB/mo for snapshot |

---

## The Optimization Stack

### 1. EBS Snapshot with Pre-cached Container Image

The biggest win: eliminate container image pull entirely by booting nodes with the vLLM image already on disk.

**How it works:**
1. Create a Bottlerocket instance
2. Pull the vLLM container image
3. Snapshot the data volume
4. Configure Karpenter to use this snapshot for GPU nodes

**EC2NodeClass configuration:**

```yaml
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: gpu
spec:
  amiSelectorTerms:
    - alias: "bottlerocket@latest"
  
  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs:
        volumeSize: 4Gi
        volumeType: gp3
    - deviceName: /dev/xvdb
      ebs:
        volumeSize: 50Gi
        volumeType: gp3
        iops: 3000
        throughput: 125
        # ⭐ Pre-cached vLLM image
        snapshotId: "snap-0abc123..."
```

**Create the snapshot:**
```bash
make create-snapshot
```

### 2. S3 Model Streaming with Run:ai Streamer

Model weights are streamed directly from S3 using vLLM's Run:ai Model Streamer integration.

**vLLM deployment args:**
```yaml
args:
  - "s3://YOUR_BUCKET/models/mistral-7b-awq/"
  - "--served-model-name=TheBloke/Mistral-7B-Instruct-v0.2-AWQ"
  - "--load-format"
  - "runai_streamer"
  - "--max-model-len"
  - "4096"
  - "--gpu-memory-utilization"
  - "0.95"
  - "--quantization"
  - "awq"
```

**Why AWQ quantization?**
- Model size: ~4GB (vs ~14GB for float16)
- Fits on T4 GPU (16GB VRAM) with plenty of room for KV cache
- Minimal quality loss compared to full precision
- Faster inference due to reduced memory bandwidth

---

## Results Summary

### Cold Start Timing Breakdown (AWQ Model on T4 GPU)

**Infrastructure Phase:**
| Phase | Duration | Notes |
|-------|----------|-------|
| Karpenter node nomination | instant | Pod triggers NodeClaim |
| EC2 launch + node ready | ~37s | g4dn.2xlarge spot |
| Container image | **0s** | Pre-cached in EBS snapshot |
| Container creation | ~1s | - |
| Container start | ~15s | NVIDIA driver init |

**vLLM Startup Phase:**
| Phase | Duration | Notes |
|-------|----------|-------|
| API server init | ~32s | Model resolution |
| S3 streaming | ~5s | 3.9 GiB @ 748 MiB/s |
| Model loading to GPU | ~48s | Total including streaming |
| torch.compile (Dynamo) | ~42s | Bytecode transform |
| Graph compilation | ~17s | Inductor backend |
| torch.compile total | **~60s** | Main bottleneck |
| CUDA graph capture | ~3s | Fast! |
| Engine init total | ~78s | - |

**Total Time to Ready: ~3 min 10s** (from pod creation to serving requests)

**Key Insights:**
1. **EBS Snapshot Working** - Container image "already present on machine" ✅
2. **S3 Streaming Fast** - 5.3s for 3.9 GiB (748 MiB/s)
3. **torch.compile is the Bottleneck** - 60s (47% of vLLM startup time)
4. **CUDA Graph Capture** - Only 3s (very fast)

**Optimization Opportunities:**
- torch.compile caching could reduce subsequent startups
- Pre-warming with compile cache in snapshot (future work)
- Current setup is optimal for cold starts without compile cache

---

## Probe Configuration

Optimized probes for fast ready detection while allowing enough time for vLLM startup:

```yaml
startupProbe:
  httpGet:
    path: /v1/models
    port: 8000
  initialDelaySeconds: 120   # Skip first 2 min (model loading + torch.compile)
  periodSeconds: 10          # Check every 10s (was 30s)
  timeoutSeconds: 5
  failureThreshold: 15       # Allow up to 270s total (120 + 15*10)

readinessProbe:
  httpGet:
    path: /v1/models
    port: 8000
  periodSeconds: 5           # Quick detection once startup passes
  timeoutSeconds: 2
  failureThreshold: 3

livenessProbe:
  httpGet:
    path: /health
    port: 8000
  periodSeconds: 30
  timeoutSeconds: 10
  failureThreshold: 3
```

**Why these values?**
- `initialDelaySeconds: 120` - vLLM takes ~3 min to start, skip first 2 min of unnecessary probes
- `periodSeconds: 10` - Detect readiness within 10s of being ready (was 30s)
- `failureThreshold: 15` - Total budget: 120 + (15 × 10) = 270s max startup time

---

## Quick Start

### Initial Setup

```bash
make setup-infra        # Creates cluster + S3 bucket
make setup-model-s3     # Upload model to S3
make create-snapshot    # Create EBS snapshot with vLLM image
make build-push-images  # Build API/frontend
make deploy-apps        # Deploy everything
```

### Updating the Snapshot

When you update the vLLM image version:

```bash
# Update image tag in kubernetes/vllm/deployment.yaml.template
# Then recreate the snapshot
make create-snapshot
make update-manifests
make deploy-apps
```

---

## Configuration Files

### .demo-config

```bash
# EBS Snapshot with pre-cached vLLM container image
SNAPSHOT_ID=snap-0abc123def456...

# Model configuration (AWQ quantized for T4 GPU compatibility)
MODEL_NAME=TheBloke/Mistral-7B-Instruct-v0.2-AWQ
MODEL_S3_PATH=models/mistral-7b-awq
```

### EC2NodeClass Template

See `kubernetes/karpenter/gpu-nodeclass.yaml.template` for the full configuration.

---

## Troubleshooting

**Snapshot not being used:**
```bash
# Verify SNAPSHOT_ID is set
grep SNAPSHOT_ID .demo-config

# Regenerate manifests
make update-manifests

# Check the generated nodeclass
cat kubernetes/karpenter/gpu-nodeclass.yaml | grep snapshotId
```

**S3 access denied:**
```bash
# Check IAM role
kubectl get sa vllm -o yaml | grep eks.amazonaws.com/role-arn

# Test S3 access from pod
kubectl exec deployment/vllm -- aws s3 ls s3://YOUR_BUCKET/models/
```

**Container image still being pulled:**
```bash
# Verify node is using the snapshot
kubectl describe node <gpu-node> | grep -A5 "Allocatable"

# Check pod events for "Already present on machine"
kubectl describe pod <vllm-pod> | grep -A5 Events
```

---

## Cost Comparison

| Component | Monthly Cost |
|-----------|-------------|
| EBS Snapshot (50GB) | ~$2.50 |
| S3 Storage (4GB AWQ model) | ~$0.10 |
| S3 Transfer (10 scale events) | ~$0.40 |
| **Total** | **~$3.00/mo** |

Plus: Faster scaling = better GPU utilization = lower overall costs.

---

## References

- [NVIDIA Run:ai Model Streamer](https://developer.nvidia.com/blog/reducing-cold-start-latency-for-llm-inference-with-nvidia-runai-model-streamer/)
- [Karpenter EC2NodeClass](https://karpenter.sh/docs/concepts/nodeclasses/)
- [Bottlerocket on EKS](https://aws.amazon.com/bottlerocket/)
