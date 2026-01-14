# Architecture Overview

## System Design

The Tube Demo runs a complete LLM inference pipeline on EKS:

```
┌─────────────────────────────────────────────────────────────┐
│ Audience (QR Code) + Laptop k6 Load                         │
└────────────────────┬────────────────────────────────────────┘
                     │ HTTP POST /v1/chat/completions
                     ▼
┌─────────────────────────────────────────────────────────────┐
│ Frontend (React/Next.js)  API Gateway (FastAPI)             │
│ - Quiz mode: text input   - Proxies to vLLM                │
│ - Survey mode: form       - Stores responses (S3)          │
└────────────────────┬────────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────────┐
│ vLLM Deployment (Llama 3.1 8B)                              │
│ - Exposes Prometheus metrics (vllm_num_requests_waiting)   │
│ - Running on GPU Spot nodes (g5.2xlarge, g5.4xlarge)      │
└────────────────────┬────────────────────────────────────────┘
                     │
        ┌────────────┼────────────┐
        │            │            │
        ▼            ▼            ▼
   OTEL Collector  KEDA Scaler  Karpenter
   (5s scrape)     (10s poll)   (node provisioner)
        │
        └────────────┬─────────────┘
                     │
              ┌──────▼──────┐
              │ Replicas:   │
              │ 1→10 pods   │
              └──────┬──────┘
                     │
              ┌──────▼──────┐
              │ GPU Nodes:  │
              │ 1→3 Spot    │
              └─────────────┘
```

## Key Components

### 1. vLLM (Inference)
- **Model**: Llama 3.1 8B Instruct
- **Node**: g5.2xlarge, g5.4xlarge, g5.12xlarge (A10G GPU)
- **Metrics**: Queue length, TTFT, token throughput
- **Replicas**: 1-10 (scaled by KEDA)

### 2. KEDA (Pod Autoscaling)
- **Trigger**: `sum(vllm_num_requests_waiting{app=vllm}) * 50`
- **Logic**: 1 real request = 50 virtual commuters
- **Scaling Modifiers**: Formula-based target calculation
- **Polling**: 10-second evaluation window
- **Metrics Source**: Kedify OTEL Scaler with in-memory TSDB

### 3. Karpenter (Node Autoscaling)
- **Default NodePool**: General-purpose (c/m/r families, on-demand) for apps
- **GPU NodePool**: Spot g5 instances (2xlarge, 4xlarge, 12xlarge) for inference
- **Spot Diversification**: Multiple instance sizes for better availability
- **Disruption Budgets**: 0% eviction during active scaling
- **Fast Boot**: Bottlerocket 1.50.0 AMI for quick provisioning
- **NodePool Management**: GPU NodePool defined in Kubernetes manifests, default in Terraform

### 4. OpenTelemetry Collector + Kedify OTEL Scaler
- **Scrape Interval**: 5 seconds (low latency)
- **Storage**: In-memory TSDB for fast queries
- **Metrics**: vLLM queue length, request counts
- **Integration**: Direct KEDA trigger without external Prometheus

### 5. API Gateway (FastAPI)
- **Endpoints**:
  - `/v1/chat/completions` - OpenAI-compatible proxy
  - `/config` - Mode detection (quiz/survey)
  - `/api/survey/submit` - Store responses
  - `/api/survey/winners` - Fetch winners
- **Mode Storage**: ConfigMap (no database)

### 6. Frontend (React/Next.js)
- **Modes**:
  - **Quiz** (0-28 min): Text input → questions
  - **Survey** (28-30 min): Rating (1-5) + company name
- **Winner Detection**: Polling `/api/survey/winners` every 2 seconds

## Demo Load Profile

| Time | k6 VUs | Audience | Total RPS | Virtual Queue | vLLM Replicas | GPU Nodes |
|------|--------|----------|-----------|---------------|---------------|-----------|
| 0m   | 2      | 0        | 2         | 0-10          | 1             | 1         |
| 2-4m | 2      | 5-10     | 5-10      | 50-250        | 2-5           | 1-2       |
| 4-28m| 2-3    | 1-3      | 3-5       | 30-150        | 3-4           | 1         |
| 28-30m| 0     | 0        | 0         | 0             | 1 (cooldown)  | 1 (consolidate) |

## Scaling Formulas

### KEDA Scaling Modifier
```
formula: clamp_min(current_queue * 50, 1)
target: 50
```

Example:
- Queue depth = 2 requests
- Formula: 2 * 50 = 100 virtual
- Target replicas: 100 / 50 = 2 pods

### Karpenter Node Provisioning
When vLLM pods become Pending (after KEDA scales):
1. Karpenter detects Pending pods
2. Matches against GPU NodePool requirements
3. Provisions g5.2xlarge Spot instance
4. Pod binds, vLLM starts

## Network & Storage

- **vLLM Model**: In-memory (ephemeral)
- **Survey Responses**: S3 bucket (`ai-workloads-tube-demo-responses`)
- **Cluster DNS**: CoreDNS (default)
- **Ingress**: ALB Ingress Controller (optional)

## Cost Optimization

- **Spot Instances**: ~70% savings vs on-demand
- **Disruption Budgets**: Prevent unnecessary node cycles
- **Consolidation**: When demo ends, Karpenter removes excess nodes
- **Time-sliced GPU** (future): multiple vLLM pods on 1 GPU

## Day-2 Patterns Demonstrated

1. **Reactive Scaling**: CPU/memory → slow
2. **Optimized Scaling**: vLLM queue metrics via OTEL → 10s loop
3. **Proactive Scaling**: forecast blending (future)
4. **Cost Management**: Spot instances + consolidation
5. **Reliability**: Disruption budgets, multi-NodePool
6. **Fast Metrics**: In-memory TSDB without external dependencies
