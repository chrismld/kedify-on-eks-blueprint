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
│   Cold Start: 24 seconds (optimized from 14 minutes)                    │
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
  - "runai_streamer"      # 6x faster weight loading
  - "--quantization"
  - "awq"
  - "--enforce-eager"     # Skip CUDA graph capture
  - "--max-model-len"
  - "4096"

env:
  - name: HF_HUB_OFFLINE
    value: "1"            # Use pre-cached model only
```

**Why these choices matter:**
- `runai_streamer`: Streams weights directly to GPU, reducing load time from 154s to 1.24s
- `HF_HUB_OFFLINE`: Prevents network calls to HuggingFace, uses EBS-cached model
- `enforce-eager`: Trades some inference speed for faster startup (no graph compilation)

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
          values: ["g", "p"]            # GPU instance families
      taints:
        - key: nvidia.com/gpu
          effect: NoSchedule            # Only GPU workloads here
      nodeClassRef:
        name: gpu                       # References EC2NodeClass with snapshot
```

**EC2NodeClass with Pre-cached Model:**
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
        volumeSize: 150Gi
        volumeType: gp3
        snapshotID: snap-XXXXXXXXX      # Pre-cached Mistral 7B (generated by make optimize-vllm)
```

**The Snapshot Strategy:**

Instead of downloading the model on every node boot, we:
1. Pre-download the model to an EBS volume
2. Create a snapshot of that volume
3. Karpenter attaches the snapshot to new GPU nodes
4. vLLM finds the model already on disk

Result: Node-to-serving in ~60 seconds instead of ~15 minutes.

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
T+75s   vLLM loads model (24s with optimizations)
T+75s   Pod ready, serving requests
```

**Total scale-up time: ~75 seconds** (dominated by node provisioning)

For faster scaling, keep a warm pool of nodes or use pod-level scaling on existing nodes.

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

Karpenter can choose from multiple GPU instance types. Here's how they compare for this workload:

| Instance | GPU | VRAM | Cold Start | Best For |
|----------|-----|------|------------|----------|
| g4dn.xlarge | T4 | 16GB | ~24s | Budget demos |
| g4dn.2xlarge | T4 | 16GB | ~24s | Default choice |
| g5.xlarge | A10G | 24GB | ~18s | Faster inference |
| g5.2xlarge | A10G | 24GB | ~18s | More headroom |
| g6.xlarge | L4 | 24GB | ~22s | Power efficient |

**Recommendation:** Start with g4dn for cost efficiency. Move to g5 if you need faster cold starts or larger models.

---

## Storage Architecture

### Model Storage: EBS Snapshots

```
┌─────────────────────────────────────────────────────────────┐
│                    EBS Snapshot (150GB)                      │
│  /local/model-cache/                                        │
│    └── models--TheBloke--Mistral-7B-Instruct-v0.2-AWQ/     │
│        ├── blobs/           (3.9GB model weights)          │
│        ├── snapshots/       (version pointers)             │
│        └── refs/            (branch references)            │
└─────────────────────────────────────────────────────────────┘
                              │
                              │ Attached on node boot
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    Bottlerocket Node                         │
│  /local/ (mounted from /dev/xvdb)                           │
│    └── model-cache/...                                      │
└─────────────────────────────────────────────────────────────┘
                              │
                              │ hostPath volume mount
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                      vLLM Container                          │
│  /mnt/models/model-cache/...                                │
│  HUGGINGFACE_HUB_CACHE=/mnt/models/model-cache              │
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

### 3. Right-sized Instances

The 4-bit quantized model (3.9GB) fits on a T4 (16GB VRAM). No need for expensive A100s.

### 4. Fast Cold Starts

24-second cold starts mean we can scale aggressively without over-provisioning "just in case."

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
- Model cached on encrypted EBS
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
2. **Cold starts can be fast** (24s, not 14 minutes)
3. **Spot instances work** for inference workloads
4. **Custom metrics beat CPU/memory** for scaling decisions
5. **Karpenter + KEDA** is a powerful combination for GPU workloads

The patterns here apply beyond demos—this is how you'd run production inference at scale.
