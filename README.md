# 🚇 AI Workloads Tube Demo: From Reactive to Proactive Scaling

Welcome to the **Kubernetes Autoscaling on EKS** live demo. This project brings the London Underground to life as a Kubernetes scaling playground—where audience load triggers KEDA and Karpenter to manage vLLM inference pods and GPU nodes in real-time.

## What You'll See

Scan a QR code and ask questions about the Tube. Each question enters a queue—the queue depth multiplies by 50x in our scaling math, creating "virtual rush hour" even with a small audience. KEDA scales the number of vLLM inference pods. Karpenter provisions GPU nodes to handle the load. After 28 minutes, the app flips to survey mode where attendees rate the speaker and their company—then two lucky people win the "Kubernetes Autoscaling" book.

This is a **production-grade demo** of:
- **KEDA** scaling on vLLM queue metrics using Kedify OTEL Scaler (not just CPU)
- **Karpenter** provisioning Spot GPU instances with disruption budgets
- **OpenTelemetry** collecting metrics at 5-second intervals
- **Kedify's KEDA distribution** with OTEL add-on for real-time metric-based scaling
- **Kedify's offline mode** for a fully self-contained cluster

## Quick Start

### Prerequisites
- **AWS Account** with permissions to create EKS, EC2, IAM roles
- **Terraform** >= 1.3.2
- **kubectl** configured
- **Docker** with buildx (for multi-arch builds)
- **k6** (load testing, install via `brew install k6` or `go install github.com/grafana/k6@latest`)
- **jq** for JSON processing

### Setup (30-40 minutes)

```bash
# 1. Clone and navigate
git clone https://github.com/christianhxc/kedify-on-eks-blueprint.git
cd kedify-on-eks-blueprint

# 2. Configure AWS region and ECR (see terraform/terraform.tfvars.example)
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# Edit terraform/terraform.tfvars with your region and desired instance diversification

# 3. Deploy infrastructure
make setup-infra

# 4. Build and push container images
make build-push-images

# 5. Deploy applications
make deploy-apps

# 6. Verify everything is running
kubectl get pods -A
kubectl get nodes
```

### Run the 30-Minute Demo

```bash
make run-demo
```

This starts:
- **Amplified load generator** (audience questions × 50)
- **Terminal dashboard** with real-time Tube-themed visualization
- **Port-forwards** for API and OTEL scaler

The script will display the frontend URL. Share this with your audience via QR code!

**Demo Flow:**
1. **Minutes 0-2**: Audience scans QR code and submits ONE question about the Tube
2. **Minutes 2-25**: Present while dashboard shows live scaling (questions amplified 50x)
3. **Minutes 25-28**: Switch to survey mode
4. **Minutes 28-30**: Draw winners

At **T+25 minutes**, switch to survey mode:

```bash
make enable-survey
```

This flips the app to survey mode. At **T+28 minutes**, pick winners:

```bash
make pick-winners
```

When done:

```bash
make teardown
```

## Architecture at a Glance

```
                    ┌─────────────────────────────────────┐
                    │  Audience + Laptop k6 Load          │
                    │  (QR code questions)                │
                    └──────────────┬──────────────────────┘
                                   │
                    ┌──────────────▼──────────────┐
                    │   Frontend (Next.js static) │
                    │   API Gateway (FastAPI)     │
                    └──────────────┬──────────────┘
                                   │
                    ┌──────────────▼──────────────┐
                    │  vLLM Pods (queue_length)   │
                    │  Metrics → OTEL Collector   │
                    └──────────────┬──────────────┘
                                   │
                    ┌──────────────▼──────────────┐
                    │  KEDA (Kedify OTEL Scaler)  │
                    │  queue * 50 = replicas      │
                    └──────────────┬──────────────┘
                                   │
                    ┌──────────────▼──────────────┐
                    │  Karpenter (GPU NodePool)   │
                    │  Spot g5.2xlarge, g5.4xl... │
                    │  Bottlerocket AMI           │
                    └─────────────────────────────┘
```

**Key components:**
- **vLLM**: Llama 3.1 8B Instruct on GPU
- **KEDA**: Scales pods on `vllm_num_requests_waiting * 50` via OTEL scaler
- **Karpenter**: Manages GPU Spot nodes with disruption budgets
- **OpenTelemetry**: 5-second scrape interval with in-memory TSDB
- **Kedify OTEL Add-on**: Real-time metric collection and scaling
- **AWS ALB**: Internet-facing Application Load Balancer for frontend access

## Files & Structure

```
├── terraform/              EKS cluster, Karpenter controller, KEDA, OTEL scaler
├── app/                    FastAPI gateway + React frontend
├── kubernetes/             K8s manifests (vLLM, KEDA, Karpenter NodePools)
├── scripts/                Demo automation (run, enable survey, pick winners)
├── docs/                   Extended documentation
└── Makefile                One-command setup, build, deploy, demo, cleanup
```

## Day-2 Patterns Covered

### KEDA
- **Triggers**: vLLM queue length via Kedify OTEL scaler (not HTTP RPS)
- **Scaling Modifiers**: Formula-based tuning (`current * 50`)
- **Real-time Metrics**: In-memory TSDB for fast scaling decisions
- **Pause/Resume**: ConfigMap flip for demo flow

### Karpenter
- **Multiple NodePools**: GPU (g5.2xlarge, g5.4xlarge, g5.12xlarge) + CPU (Graviton)
- **Spot Diversification**: Price-capacity-optimized across instance types
- **Disruption Budgets**: Prevent node evictions during scaling surge
- **Fast Boot**: Bottlerocket AMI for quick node provisioning

### Production Patterns
- **OTEL scrape**: 5-second intervals for responsiveness
- **KEDA polling**: 10-second evaluation window
- **In-memory TSDB**: Fast metric queries without external dependencies
- **Survey mode**: ConfigMap-driven UI flip (no redeployment)

## Troubleshooting

### vLLM pod stuck in Pending
Check Karpenter logs: `kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter -f`

### KEDA not scaling
1. Verify OTEL scaler is collecting metrics: `kubectl port-forward -n keda svc/keda-otel-scaler 8080:8080`
2. Check metrics at http://localhost:8080/metrics for `vllm_num_requests_waiting`
3. Check ScaledObject status: `kubectl describe scaledobject vllm-queue-scaler`
4. View OTEL collector logs: `kubectl logs -n keda -l app.kubernetes.io/name=otel-collector -f`

### Survey mode not switching
Run again: `make enable-survey` and watch frontend logs: `kubectl logs -f deployment/frontend`

See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) for more.

## Survey & Raffle Details

Attendees rate the session (1-5) and provide their company name—no PII. Winners see a banner on the frontend saying they won "Kubernetes Autoscaling" book. Presenters can verify by checking S3 responses.

## Costs

This demo runs on **AWS Spot instances**:
- **GPU nodes** (g5.2xlarge Spot): ~$0.40/hour each
- **CPU nodes** (t4g.medium Spot): ~$0.03/hour
- **EBS + EKS**: ~$0.10/hour
- **Total**: ~$2-5 for a 30-minute demo

Cleanup removes all resources.

## Contributing

Found a bug? Have a better Tube pun? Open an issue or PR.

## License

MIT License – see [LICENSE](LICENSE)

## Credits

Demo designed for showcasing **Kubernetes Autoscaling on EKS** by [@christianhxc](https://github.com/christianhxc).

Inspired by real-world KEDA + Karpenter deployments and the brilliant London Underground.

---

**Happy scaling! 🚇⚡**
