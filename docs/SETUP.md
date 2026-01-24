# Setup Guide: From Zero to Serving in 40 Minutes

This guide walks you through deploying the complete LLM inference stack on EKS. By the end, you'll have a production-ready system with GPU autoscaling, optimized cold starts, and a live demo you can share with an audience.

---

## What You're Building

```
Your Laptop                          AWS
┌──────────────┐                    ┌─────────────────────────────────┐
│ make commands│───terraform───────▶│ EKS Cluster                     │
│ kubectl      │                    │ ├── Karpenter (node scaling)    │
│ browser      │◀──ALB/CloudFront───│ ├── KEDA (pod scaling)          │
└──────────────┘                    │ ├── vLLM (GPU inference)        │
                                    │ ├── API (FastAPI)               │
                                    │ ├── Frontend (Next.js)          │
                                    │ └── S3 (model storage)          │
                                    └─────────────────────────────────┘
```

**Time breakdown:**
- Infrastructure (EKS, Karpenter, S3): ~20 minutes
- Model upload to S3: ~5 minutes
- Application deployment: ~5-10 minutes
- **Total: ~35-40 minutes**

---

## Architecture Highlights

This setup uses several optimizations for fast cold starts:

1. **EBS Snapshot with Pre-cached Image** - Container image is pre-loaded on the data volume, eliminating pull time
2. **SOCI Snapshotter** - Fallback for any images not in the snapshot (lazy loading)
3. **S3 Model Streaming** - vLLM streams model weights directly from S3 via Run:ai Streamer

### Creating the EBS Snapshot (Optional but Recommended)

For the fastest cold starts (~90 seconds), create an EBS snapshot with the vLLM image pre-cached:

```bash
# After setup-infra, create the snapshot
make create-snapshot
```

This takes ~10-15 minutes and:
1. Launches a temporary Bottlerocket instance
2. Pulls the vLLM container image from ECR
3. Creates an EBS snapshot of the data volume
4. Updates `.demo-config` with the snapshot ID

Without the snapshot, cold starts take ~3-4 minutes (SOCI parallel pull).

---

## Prerequisites

### AWS Account Requirements

You'll need an AWS account with:
- **Permissions**: EC2, EKS, IAM, S3, ECR, EBS
- **Service quotas**: At least 4 GPU instances (g4dn or g5) in your region
- **Spot capacity**: Check the Spot Instance advisor for your region

### Local Tools

Install these before starting:

```bash
# macOS (recommended)
brew install terraform kubectl aws-cli docker jq pipx

# For model upload (HuggingFace CLI)
pipx install huggingface_hub   # Provides 'hf' command

# Authenticate with HuggingFace (required for faster downloads)
# Get a token from: https://huggingface.co/settings/tokens
hf auth login

# Verify installations
terraform --version    # >= 1.5
kubectl version        # >= 1.28
aws --version          # >= 2.0
docker --version       # >= 24.0
```

### AWS Authentication

```bash
# Configure credentials
aws configure

# Verify access
aws sts get-caller-identity
```

### Docker Buildx (for multi-arch images)

```bash
# Create builder for amd64/arm64
docker buildx create --name multiarch --use
docker buildx inspect --bootstrap
```

---

## Step 1: Clone and Configure (5 minutes)

### Get the Code

```bash
git clone <repository-url>
cd <project-directory>
```

### Configure Terraform Variables

```bash
# Copy the example configuration
cp terraform/terraform.tfvars.example terraform/terraform.tfvars

# Edit with your preferences
vim terraform/terraform.tfvars
```

**Key variables to set:**

```hcl
# terraform/terraform.tfvars

# Required: Your preferred region
region = "eu-west-1"

# Required: Unique project name (used for S3 buckets, ECR repos)
project_name = "tube-demo"
```

**Region selection tips:**
- `eu-west-1` (Ireland): Good Spot availability, low latency to EU
- `us-west-2` (Oregon): Best Spot availability, good for US demos
- `us-east-1` (Virginia): Largest region, but can have capacity issues

---

## Step 2: Deploy Infrastructure (20 minutes)

This creates the EKS cluster, Karpenter, S3 bucket, and supporting infrastructure.

```bash
make setup-infra
```

**What's happening:**
1. VPC with public/private subnets
2. EKS cluster with managed node group (for system pods)
3. Karpenter controller + NodePools with SOCI snapshotter
4. S3 bucket for model storage
5. IAM roles for vLLM to access S3
6. AWS Load Balancer Controller
7. ECR repositories for your images

**Watch the progress:**
```bash
# In another terminal
cd terraform && terraform output  # See created resources
kubectl get pods -A               # Watch pods come up
```

**Expected output when complete:**
```
Apply complete! Resources: 47 added, 0 changed, 0 destroyed.

Outputs:
cluster_endpoint = "https://xxx.eks.amazonaws.com"
cluster_name = "gpu-inference-demo"
models_bucket_name = "kedify-on-eks-blueprint-models-123456789"
```

### Verify the Cluster

```bash
# Update kubeconfig
aws eks update-kubeconfig --name kedify-on-eks-blueprint --region eu-west-1

# Check system pods
kubectl get pods -n kube-system
kubectl get pods -n karpenter
```

All pods should be `Running` before proceeding.

---

## Step 3: Create EBS Snapshot (Optional, 10-15 minutes)

For the fastest cold starts, create an EBS snapshot with the vLLM image pre-cached:

```bash
make create-snapshot
```

**What's happening:**
1. Launches a temporary Bottlerocket EC2 instance
2. Authenticates with ECR and pulls the vLLM image
3. Stops the instance and creates an EBS snapshot
4. Updates `.demo-config` with the snapshot ID
5. Cleans up the temporary instance

**Skip this step** if you're okay with ~3-4 minute cold starts (SOCI will handle image pulls).

---

## Step 4: Upload Model to S3 (5 minutes)

Upload the Mistral 7B AWQ quantized model to S3 for streaming.

```bash
make setup-model-s3
```

**What's happening:**
1. Downloads AWQ quantized model from HuggingFace (~4GB)
2. Uploads to S3 bucket
3. Updates vLLM deployment manifest with S3 path

**Note:** This only needs to be done once. The model persists in S3.

**Why AWQ?** The quantized model is ~4GB vs ~14GB for full precision, allowing it to run on T4 GPUs (16GB VRAM) with plenty of room for KV cache.

---

## Step 5: Build and Push Images (10 minutes)

Build the API and frontend containers and push to ECR.

```bash
make build-push-images
```

**What's happening:**
1. Builds multi-arch images (amd64 + arm64)
2. Pushes to ECR repositories created in Step 2
3. Updates Kubernetes manifests with correct image URIs

**Verify images are pushed:**
```bash
aws ecr describe-images --repository-name tube-demo/api
aws ecr describe-images --repository-name tube-demo/frontend
```

---

## Step 6: Deploy Applications (5-10 minutes)

Deploy vLLM, API, and frontend to the cluster.

```bash
make deploy-apps
```

**What's happening:**
1. Applies Kubernetes manifests from `kubernetes/`
2. Karpenter provisions a GPU node with SOCI snapshotter
3. vLLM pod starts and streams model from S3

**Watch the deployment:**
```bash
# Watch pods
kubectl get pods -w

# Watch Karpenter provision a GPU node
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter -f

# Watch vLLM load the model
kubectl logs -f deployment/vllm
```

**Success indicators in vLLM logs:**
```
Loading safetensors from S3...
[RunAI Streamer] Overall time to stream 3.9 GiB: X.XXs
Model loading took X.XX GiB memory and XX.XX seconds
Starting vLLM API server on http://0.0.0.0:8000
```

---

## Step 7: Get the Frontend URL

```bash
make get-frontend-url
```

This returns the ALB URL where your frontend is accessible. Open it in a browser to verify everything works.

**Test the inference:**
1. Open the frontend URL
2. Type a question about the London Underground
3. You should get a response in 2-5 seconds

---

## Step 8: Run the Demo (Optional)

If you're presenting this to an audience:

```bash
# Start the load generator and dashboard
make run-demo
```

This opens a terminal dashboard showing:
- Current request queue depth
- vLLM replica count
- GPU node count
- Response latencies

**Generate a QR code for audience participation:**
```bash
make generate-qr
```

**Switch to survey mode (last 2 minutes of demo):**
```bash
make enable-survey
```

**Pick winners:**
```bash
make pick-winners
```

---

## Step 9: Cleanup

When you're done, tear everything down:

```bash
make teardown
```

This destroys:
- All Kubernetes resources
- EKS cluster
- Karpenter-provisioned nodes
- EBS snapshot (if created)
- S3 bucket (including model)
- ECR repositories
- VPC and networking

---

## Quick Reference

### Common Commands

| Command | Description | Time |
|---------|-------------|------|
| `make setup-infra` | Create EKS + Karpenter + S3 | 20 min |
| `make create-snapshot` | Create EBS snapshot with vLLM image | 10-15 min |
| `make setup-model-s3` | Upload model to S3 | 5 min |
| `make build-push-images` | Build and push containers | 10 min |
| `make update-manifests` | Regenerate K8s manifests | instant |
| `make deploy-apps` | Deploy all applications | 5-10 min |
| `make get-frontend-url` | Get the demo URL | instant |
| `make run-demo` | Start load gen + dashboard | instant |
| `make teardown` | Destroy everything | 10 min |

### Useful kubectl Commands

```bash
# Check all pods
kubectl get pods -A

# Watch vLLM logs
kubectl logs -f deployment/vllm

# Check GPU node
kubectl get nodes -l intent=gpu-inference

# Scale vLLM manually
kubectl scale deployment vllm --replicas=3

# Check Karpenter decisions
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter

# Check KEDA scaling
kubectl get scaledobject
kubectl describe scaledobject vllm-scaler
```

### Environment Variables

The API reads these from its ConfigMap/environment:

| Variable | Default | Description |
|----------|---------|-------------|
| `VLLM_ENDPOINT` | `http://vllm-service:8000` | vLLM service URL |
| `DEMO_MODE` | `quiz` | Current mode (quiz/survey) |
| `AWS_REGION` | `eu-west-1` | Region for S3 |
| `PROJECT_NAME` | `tube-demo` | Used for S3 bucket names |

---

## Troubleshooting

### vLLM pod stuck in Pending

**Cause:** No GPU node available

**Fix:**
```bash
# Check if Karpenter is provisioning
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter | tail -20

# Check NodePool
kubectl get nodepool gpu-inference -o yaml

# Verify Spot capacity in your region
# Try a different instance type or region
```

### vLLM fails to load model from S3

**Cause:** IAM permissions or bucket path issues

**Fix:**
```bash
# Check vLLM logs for S3 errors
kubectl logs deployment/vllm | grep -i s3

# Verify service account has correct role
kubectl get sa vllm -o yaml

# Test S3 access from pod
kubectl exec deployment/vllm -- aws s3 ls s3://YOUR_BUCKET/models/
```

### Slow container image pull

**Cause:** EBS snapshot not configured or image not in snapshot

**Fix:**
```bash
# Check if snapshot is configured
grep SNAPSHOT_ID .demo-config

# If empty, create the snapshot
make create-snapshot
make update-manifests
make deploy-apps

# Verify EC2NodeClass has snapshotID
kubectl get ec2nodeclass gpu -o yaml | grep snapshotID
```

If you don't want to use snapshots, SOCI will still provide faster pulls than default (~3-4 min vs ~6-8 min).

### "Processing your question..." error in UI

**Cause:** API can't reach vLLM or model name mismatch

**Fix:**
```bash
# Check vLLM is running
kubectl get pods -l app=vllm

# Check vLLM logs for errors
kubectl logs deployment/vllm

# Test vLLM directly
kubectl exec -it deployment/api -- curl http://vllm-service:8000/v1/models
```

### KEDA not scaling vLLM pods

**Cause:** OTel collector not scraping metrics or metric name mismatch

**Fix:**
```bash
# Check ScaledObject status
kubectl get scaledobject vllm-queue-scaler -o yaml

# Check OTel collector is running
kubectl get pods -n keda -l app.kubernetes.io/name=scrape-vllm-collector

# Check OTel collector logs
kubectl logs -n keda -l app.kubernetes.io/name=scrape-vllm-collector

# Verify vLLM metrics are exposed
kubectl exec deployment/vllm -- curl -s localhost:8000/metrics | grep num_requests

# Check KEDA operator logs
kubectl logs -n keda -l app=keda-operator
```

**Note:** vLLM exposes metrics with colons (`vllm:num_requests_waiting`) but KEDA queries with underscores (`vllm_num_requests_waiting`). The OTel collector config in `kubernetes/keda/otel-collector.yaml` handles this transformation.

### Karpenter not provisioning nodes

**Cause:** IAM permissions or NodePool misconfiguration

**Fix:**
```bash
# Check Karpenter logs
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter

# Verify NodePool exists
kubectl get nodepool

# Check EC2NodeClass
kubectl get ec2nodeclass
```

### Images fail to push to ECR

**Cause:** Docker not authenticated to ECR

**Fix:**
```bash
# Re-authenticate
aws ecr get-login-password --region eu-west-1 | \
  docker login --username AWS --password-stdin \
  $(aws sts get-caller-identity --query Account --output text).dkr.ecr.eu-west-1.amazonaws.com
```

---

## Enabling KEDA Autoscaling

KEDA (with Kedify) provides queue-based autoscaling for vLLM based on the number of waiting requests.

### Prerequisites

Install Kedify (includes KEDA + OTel scaler):
```bash
# Follow Kedify installation instructions for your cluster
# This creates the 'keda' namespace with KEDA operator and kedify-otel-scaler
```

### Deploy KEDA Resources

```bash
# Apply RBAC for OTel collector to scrape pod metrics
kubectl apply -f kubernetes/keda/otel-rbac.yaml

# Apply OpenTelemetry Collector (scrapes vLLM metrics)
kubectl apply -f kubernetes/keda/otel-collector.yaml

# Apply ScaledObject (triggers autoscaling)
kubectl apply -f kubernetes/keda/scaledobject.yaml
```

### Verify Setup

```bash
# Check OTel collector is running
kubectl get pods -n keda -l app.kubernetes.io/name=scrape-vllm-collector

# Check ScaledObject is ready
kubectl get scaledobject vllm-queue-scaler

# Check HPA was created
kubectl get hpa
```

### How It Works

1. **OTel Collector** scrapes `vllm:num_requests_waiting` from vLLM pods every 5s
2. **Transform processor** renames metric to `vllm_num_requests_waiting` (KEDA compatibility)
3. **KEDA** queries the metric and scales vLLM deployment when queue > 1
4. **Karpenter** provisions GPU nodes as needed for new pods

### Load Testing

Run the k6 load test to trigger autoscaling:
```bash
# Apply the k6 job (runs inside cluster)
kubectl apply -f kubernetes/k6-load-test.yaml

# Watch the scaling
kubectl get pods -l app=vllm -w

# Check k6 progress
kubectl logs job/k6-load-test -f

# Clean up after test
kubectl delete job k6-load-test
```

---

## Next Steps

Once you have the basic setup running:

1. **Customize the model**: Edit `kubernetes/vllm/deployment.yaml` to use a different model
2. **Adjust scaling**: Modify the ScaledObject in `kubernetes/keda/` for different thresholds
3. **Add monitoring**: Deploy Prometheus + Grafana for production observability
4. **Enable CloudFront**: Run `make setup-cloudfront` for CDN + WAF protection

See [ARCHITECTURE.md](ARCHITECTURE.md) for deep dives into each component.
See [VLLM-OPTIMIZATION.md](VLLM-OPTIMIZATION.md) for the cold start optimization journey.
