# Architecture: GPU-Accelerated LLM Inference on EKS

## The Big Picture

This demo showcases a production-ready pattern for running LLM inference on Kubernetes with intelligent autoscaling. When audience members ask questions via a web UI, their requests flow through a FastAPI gateway to vLLM pods running on GPU Spot instances—all orchestrated by Karpenter for node provisioning and KEDA for pod scaling.

The magic happens in the scaling: we don't wait for CPU metrics to tell us we're overloaded. Instead, we watch vLLM's request queue directly, scaling proactively before latency degrades.

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        Audience + Load Generator                         │
│                     (QR Code → Mobile / k6 scripts)                     │
└─────────────────────────────┬───────────────────────────────────────────┘
                              │ HTTPS
                              ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                         CloudFront + ALB                                 │
│                    (Optional: WAF, caching, TLS)                        │
└─────────────────────────────┬───────────────────────────────────────────┘
                              │
              ┌───────────────┴───────────────┐
              ▼                               ▼
┌──────────────────────────┐    ┌──────────────────────────┐
│   Frontend (Next.js)     │    │   API Gateway (FastAPI)  │
│   - Quiz mode UI         │    │   - /v1/chat/completions │
│   - Survey mode UI       │    │   - Response storage (S3)│
│   - Real-time updates    │    │   - Mode management      │
└──────────────────────────┘    └─────────────┬────────────┘
                                              │
                                              ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                        vLLM Inference Pods                               │
│   ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐      │
│   │ vLLM-1  │  │ vLLM-2  │  │ vLLM-3  │  │ vLLM-4  │  │ vLLM-5  │      │
│   │ (GPU)   │  │ (GPU)   │  │ (GPU)   │  │ (GPU)   │  │ (GPU)   │      │
│   └─────────┘  └─────────┘  └─────────┘  └─────────┘  └─────────┘      │
│                                                                          │
│   Model: Mistral 7B AWQ (4-bit quantized)                               │
│   Cold Start: ~1-2 minutes (with EFS shared storage)                    │
│   Metrics: /metrics endpoint → Prometheus format                        │
└─────────────────────────────┬───────────────────────────────────────────┘
                              │
        ┌─────────────────────┼─────────────────────┐
        │                     │                     │
        ▼                     ▼                     ▼
┌───────────────┐    ┌───────────────┐    ┌───────────────┐
│     KEDA      │    │   Karpenter   │    │  OTEL Scaler  │
│  Pod Scaling  │    │ Node Scaling  │    │   (Kedify)    │
│  1→10 pods    │    │ 1→5 GPU nodes │    │  5s scrape    │
└───────────────┘    └───────────────┘    └───────────────┘
                              │
                              ▼
                    ┌───────────────┐
                    │      EFS      │
                    │ Model Storage │
                    │  (Shared)     │
                    └───────────────┘
```

---

## Core Components

### vLLM: The Inference Engine

vLLM serves our Mistral 7B model with an OpenAI-compatible API. The key architectural decisions:

**Model Choice: Mistral 7B AWQ**
- 4-bit quantized (AWQ) for reduced memory footprint
- Fits comfortably on a single A10G (24GB) or T4 (16GB) GPU
- Fast inference with good quality for demo purposes

**Optimized Cold Start Configuration:**
```yaml
args:
  - "TheBloke/Mistral-7B-Instruct-v0.2-AWQ"
  - "--load-format"
  - "runai_streamer"      # Concurrent weight streaming
  - "--quantization"
  - "awq"
  - "--enforce-eager"     # Skip CUDA graph capture
  - "--max-model-len"
  - "4096"

env:
  - name: HF_HUB_OFFLINE
    value: "1"            # Use pre-cached model only (from EFS)

volumes:
  - name: model-storage
    persistentVolumeClaim:
      claimName: efs-models-pvc  # Shared EFS storage
```

**Why these choices matter:**
- `runai_streamer`: Streams weights concurrently to GPU
- `HF_HUB_OFFLINE`: Prevents network calls to HuggingFace, uses EFS-cached model
- `enforce-eager`: Trades some inference speed for faster startup (no graph compilation)
- `EFS PVC`: Shared storage enables scale-to-zero without losing the model

---

### Karpenter: Just-in-Time GPU Nodes

Karpenter provisions GPU nodes on-demand when vLLM pods can't be scheduled. This is critical for cost optimization—we don't pay for idle GPUs.

**GPU NodePool Configuration:**
```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: gpu-inference
spec:
  template:
    spec:
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot"]              # 70% cost savings
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["g", "p"]            # GPU instance categories
        - key: karpenter.k8s.aws/instance-gpu-manufacturer
          operator: In
          values: ["nvidia"]            # NVIDIA GPUs only
      taints:
        - key: nvidia.com/gpu
          effect: NoSchedule            # Only GPU workloads here
      nodeClassRef:
        name: gpu                       # References EC2NodeClass with snapshot
```

**EC2NodeClass with Container Image Cache:**
```yaml
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: gpu
spec:
  amiSelectorTerms:
    - alias: bottlerocket@latest        # AWS-maintained, auto-updates
  
  blockDeviceMappings:
    - deviceName: /dev/xvdb             # Data volume
      ebs:
        volumeSize: 50Gi
        volumeType: gp3
        snapshotID: snap-XXXXXXXXX      # Pre-cached container image (generated by make optimize-vllm)
```

**The Storage Strategy:**

We use a hybrid approach:
1. **EFS** for model weights (shared, persists across scale-to-zero)
2. **EBS snapshot** for container images (faster pulls on new nodes)

Result: Node-to-serving in ~90 seconds (dominated by EFS model loading).

---

### KEDA + Kedify OTEL Scaler: Intelligent Pod Scaling

Traditional HPA watches CPU/memory—useless for LLM inference where the bottleneck is GPU and request queue depth. KEDA lets us scale on custom metrics.

**The Scaling Signal: vLLM Queue Depth**

vLLM exposes `vllm:num_requests_waiting`—the number of requests queued for processing. This is the perfect scaling signal because:
- It's leading (queue grows before latency spikes)
- It's specific (directly measures inference backlog)
- It's fast (updates in real-time)

**Kedify OTEL Scaler Architecture:**
```
vLLM Pod ──metrics──▶ OTEL Collector ──store──▶ In-Memory TSDB
                           │
                           ▼
                      KEDA Scaler ──query──▶ Scale Decision
```

**Why not Prometheus?**
- Prometheus adds latency (scrape interval + query time)
- Requires additional infrastructure
- Kedify's OTEL scaler has a built-in TSDB with 5-second resolution

**ScaledObject Configuration:**
```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: vllm-scaler
spec:
  scaleTargetRef:
    name: vllm
  minReplicaCount: 1
  maxReplicaCount: 10
  
  triggers:
    - type: kedify-otel
      metadata:
        query: "sum(vllm_num_requests_waiting)"
        targetValue: "2"        # Scale up when queue > 2 per pod
        clusterName: "default"
```

---

### API Gateway: The Traffic Router

A lightweight FastAPI service that:
1. Proxies requests to vLLM (OpenAI-compatible)
2. Manages demo modes (quiz → survey)
3. Stores responses in S3

**Key Endpoint:**
```python
@app.post("/api/question/submit")
async def submit_question(data: dict):
    # Forward to vLLM
    async with httpx.AsyncClient(timeout=30.0) as client:
        response = await client.post(
            f"{VLLM_ENDPOINT}/v1/chat/completions",
            json={
                "model": "TheBloke/Mistral-7B-Instruct-v0.2-AWQ",
                "messages": [...],
                "max_tokens": 150
            }
        )
    return response.json()
```

---

## Scaling Dynamics

### The Scaling Timeline

When load increases, here's what happens:

```
T+0s    Request arrives, queue depth increases
T+5s    OTEL Collector scrapes new metric
T+10s   KEDA evaluates ScaledObject, decides to scale
T+11s   New vLLM pod created (Pending)
T+12s   Karpenter detects Pending pod
T+15s   Karpenter launches Spot instance
T+45s   Node ready, joins cluster
T+50s   Pod scheduled to new node
T+55s   Container starts (image cached in EBS snapshot)
T+120s  vLLM loads model from EFS (~60-90s)
T+120s  Pod ready, serving requests
```

**Total scale-up time: ~2 minutes** (dominated by EFS model loading)

For faster scaling, consider:
- FSx for Lustre instead of EFS (~30s model load)
- Keep minimum replicas > 0 (warm pods)

### The Scaling Formula

We use a "virtual commuters" multiplier for demo effect:

```
Desired Replicas = ceil(queue_depth × 50 / target_per_pod)
```

Example:
- Queue depth: 3 requests
- Multiplier: 50 (simulating 150 virtual users)
- Target per pod: 50
- Result: ceil(150 / 50) = 3 replicas

This makes scaling visually dramatic for demos while keeping actual load manageable.

---

## Instance Type Selection

Karpenter can choose from multiple GPU instance types based on the NodePool requirements (`instance-category: g, p` + `instance-gpu-manufacturer: nvidia`). Here's how they compare for this workload:

| Instance | GPU | VRAM | Cold Start | Best For |
|----------|-----|------|------------|----------|
| g4dn.xlarge | T4 | 16GB | ~24s | Budget demos |
| g4dn.2xlarge | T4 | 16GB | ~24s | Default choice |
| g5.xlarge | A10G | 24GB | ~18s | Faster inference |
| g5.2xlarge | A10G | 24GB | ~18s | More headroom |
| g6.xlarge | L4 | 24GB | ~22s | Power efficient |
| p3.2xlarge | V100 | 16GB | ~20s | High memory BW |
| p4d.24xlarge | A100 | 40GB | ~15s | Large models |
| p5.48xlarge | H100 | 80GB | ~12s | Maximum performance |

**Recommendation:** Start with g4dn/g5 for cost efficiency. The `nvidia` GPU manufacturer filter ensures AMD GPUs (like g4ad) are excluded.

---

## Storage Architecture

### Model Storage: EFS (Shared)

```
┌─────────────────────────────────────────────────────────────┐
│                    EFS Filesystem (Elastic)                  │
│  /models/model-cache/                                       │
│    └── models--TheBloke--Mistral-7B-Instruct-v0.2-AWQ/     │
│        ├── blobs/           (3.9GB model weights)          │
│        ├── snapshots/       (version pointers)             │
│        └── refs/            (branch references)            │
└─────────────────────────────────────────────────────────────┘
                              │
                              │ NFS mount (ReadWriteMany)
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    All vLLM Pods                             │
│  /mnt/models/model-cache/...                                │
│  HUGGINGFACE_HUB_CACHE=/mnt/models/model-cache              │
│                                                              │
│  Benefits:                                                   │
│  - Shared across all pods (no per-node storage)            │
│  - Persists across scale-to-zero                           │
│  - Simple model updates (re-run loader job)                │
└─────────────────────────────────────────────────────────────┘
```

### Container Image Cache: EBS Snapshot

```
┌─────────────────────────────────────────────────────────────┐
│                    EBS Snapshot (50GB)                       │
│  /local/ (Bottlerocket data volume)                         │
│    └── containerd image cache                               │
│        └── vllm/vllm-openai:v0.13.0 (~8-10GB)              │
└─────────────────────────────────────────────────────────────┘
                              │
                              │ Attached on node boot
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    Bottlerocket Node                         │
│  Container image already on disk                            │
│  Pull time: ~10s (vs ~90s without cache)                   │
└─────────────────────────────────────────────────────────────┘
```

### Response Storage: S3

Survey responses and question logs go to S3:
- Bucket: `{project_name}-responses-{account_id}`
- Versioning enabled for audit trail
- No database required—simple and serverless

---

## Cost Optimization Strategies

### 1. Spot Instances (70% savings)

All GPU nodes run on Spot. Karpenter handles interruptions gracefully:
- Diversified instance types improve availability
- Pods reschedule automatically on interruption
- Model cache persists (EBS snapshot, not instance storage)

### 2. Scale to Zero

When idle, KEDA can scale vLLM to zero pods. Karpenter then consolidates nodes:
```yaml
disruption:
  consolidationPolicy: WhenEmptyOrUnderutilized
  consolidateAfter: 30s
```

**With EFS, the model persists** even when all pods and nodes are terminated. When traffic returns, new pods mount the same EFS volume and find the model ready.

### 3. Right-sized Instances

The 4-bit quantized model (3.9GB) fits on a T4 (16GB VRAM). No need for expensive A100s.

### 4. Fast Cold Starts

~1-2 minute cold starts (with EFS) mean we can scale aggressively without over-provisioning "just in case." For even faster cold starts, consider FSx for Lustre.

---

## Security Considerations

### Network Isolation
- vLLM pods run in private subnets
- ALB handles TLS termination
- No direct internet access from GPU nodes

### IAM Least Privilege
- API pods have minimal S3 permissions
- Karpenter uses scoped IAM roles
- No broad admin access

### Model Security
- Model cached on encrypted EFS
- No HuggingFace tokens in production (offline mode)
- Container images from trusted registries

---

## Observability

### Metrics Available

| Metric | Source | Use |
|--------|--------|-----|
| `vllm:num_requests_waiting` | vLLM | Scaling trigger |
| `vllm:num_requests_running` | vLLM | Capacity monitoring |
| `vllm:gpu_cache_usage_perc` | vLLM | Memory pressure |
| Node count | Karpenter | Cost tracking |
| Pod count | KEDA | Scaling verification |

### Recommended Dashboards

1. **Scaling Dashboard**: Queue depth vs replica count over time
2. **Cost Dashboard**: Node hours by instance type
3. **Latency Dashboard**: P50/P95/P99 response times

---

## What This Demo Proves

1. **LLM inference scales on Kubernetes** with the right tooling
2. **Cold starts can be manageable** (~1-2 min with EFS, supports scale-to-zero)
3. **Spot instances work** for inference workloads
4. **Custom metrics beat CPU/memory** for scaling decisions
5. **Karpenter + KEDA** is a powerful combination for GPU workloads
6. **EFS enables operational simplicity** (shared storage, easy model updates)

The patterns here apply beyond demos—this is how you'd run production inference at scale.
