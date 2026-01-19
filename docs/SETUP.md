# Setup Guide: From Zero to Serving in 45 Minutes

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
                                    │ └── EFS (shared model storage)  │
                                    └─────────────────────────────────┘
```

**Time breakdown:**
- Infrastructure (EKS, Karpenter, KEDA, EFS): ~20 minutes
- Container image caching (EBS snapshot): ~10-15 minutes (optional)
- Application deployment + model loading: ~8-10 minutes
- **Total: ~40-45 minutes**

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
brew install terraform kubectl aws-cli docker jq

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
aws_region = "eu-west-1"

# Required: Unique project name (used for S3 buckets, ECR repos)
project_name = "tube-demo"

# Optional: Customize cluster name
cluster_name = "gpu-inference-demo"
```

**Region selection tips:**
- `eu-west-1` (Ireland): Good Spot availability, low latency to EU
- `us-west-2` (Oregon): Best Spot availability, good for US demos
- `us-east-1` (Virginia): Largest region, but can have capacity issues

---

## Step 2: Deploy Infrastructure (20 minutes)

This creates the EKS cluster, Karpenter, KEDA, EFS, and supporting infrastructure.

```bash
make setup-infra
```

**What's happening:**
1. VPC with public/private subnets
2. EKS cluster with managed node group (for system pods)
3. Karpenter controller + NodePools
4. KEDA + Kedify OTEL scaler
5. AWS Load Balancer Controller
6. EFS filesystem for shared model storage
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
```

### Verify the Cluster

```bash
# Update kubeconfig
aws eks update-kubeconfig --name gpu-inference-demo --region eu-west-1

# Check system pods
kubectl get pods -n kube-system
kubectl get pods -n karpenter
kubectl get pods -n keda
```

All pods should be `Running` before proceeding.

---

## Step 3: Optimize Container Image Pulls (10-15 minutes) - Optional

This step creates an EBS snapshot with the vLLM container image pre-cached, reducing image pull time from ~90 seconds to ~10 seconds on new nodes.

```bash
make optimize-vllm
```

**What's happening:**
1. Launches a temporary EC2 instance (Bottlerocket)
2. Pulls the vLLM container image (~8-10 GB)
3. Creates an EBS snapshot of the data volume
4. Updates Karpenter's EC2NodeClass to use the snapshot
5. Cleans up the temporary instance

**Note:** Model weights are stored in EFS (shared storage), not in this snapshot. This step only optimizes container image pulls.

**You can skip this step** if you're okay with ~90 second image pulls on new nodes. The model loading time (~1-2 min from EFS) is the same either way.

---

## Step 4: Build and Push Images (10 minutes)

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

## Step 5: Deploy Applications (8-10 minutes)

Deploy vLLM, API, and frontend to the cluster. On first run, this also downloads the model to EFS.

```bash
make deploy-apps
```

**What's happening:**
1. Applies Kubernetes manifests from `kubernetes/`
2. Creates EFS PersistentVolume and PersistentVolumeClaim
3. Runs model-loader Job to download Mistral 7B to EFS (first time only, ~3-5 min)
4. Karpenter provisions a GPU node
5. vLLM pod starts and loads the model from EFS

**Watch the deployment:**
```bash
# Watch the model loader job (first time only)
kubectl logs -f job/model-loader

# Watch pods
kubectl get pods -w

# Watch Karpenter provision a GPU node
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter -f

# Watch vLLM load the model
kubectl logs -f deployment/vllm
```

**Success indicators in vLLM logs:**
```
HF_HUB_OFFLINE is True, replace model_id [...] to model_path [...]
Loading safetensors using Runai Model Streamer: 100% Completed
[RunAI Streamer] Overall time to stream 3.9 GiB: X.XXs
Model loading took X.XX GiB memory and XX.XX seconds
Starting vLLM API server on http://0.0.0.0:8000
```

---

## Step 6: Get the Frontend URL

```bash
make get-frontend-url
```

This returns the ALB URL where your frontend is accessible. Open it in a browser to verify everything works.

**Test the inference:**
1. Open the frontend URL
2. Type a question about the London Underground
3. You should get a response in 2-5 seconds

---

## Step 7: Run the Demo (Optional)

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

## Step 8: Cleanup

When you're done, tear everything down:

```bash
make teardown
```

This destroys:
- All Kubernetes resources
- EKS cluster
- Karpenter-provisioned nodes
- ECR repositories
- VPC and networking

**Note:** The EBS snapshot is NOT deleted (it's cheap to keep). Delete manually if needed:
```bash
aws ec2 delete-snapshot --snapshot-id $(cat .snapshot-id)
```

---

## Quick Reference

### Common Commands

| Command | Description | Time |
|---------|-------------|------|
| `make setup-infra` | Create EKS + Karpenter + KEDA + EFS | 20 min |
| `make optimize-vllm` | Create container image snapshot (optional) | 10-15 min |
| `make build-push-images` | Build and push containers | 10 min |
| `make deploy-apps` | Deploy all applications + load model | 8-10 min |
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

**Cause:** No GPU node available or EFS PVC not bound

**Fix:**
```bash
# Check if Karpenter is provisioning
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter | tail -20

# Check PVC is bound
kubectl get pvc efs-models-pvc

# Check NodePool
kubectl get nodepool gpu-inference -o yaml

# Verify Spot capacity in your region
# Try a different instance type or region
```

### Model loader job fails

**Cause:** Network issues or EFS mount problems

**Fix:**
```bash
# Check job logs
kubectl logs job/model-loader

# Check EFS mount target status
aws efs describe-mount-targets --file-system-id $(terraform -chdir=terraform output -raw efs_filesystem_id)

# Retry the job
kubectl delete job model-loader
kubectl apply -f kubernetes/efs/model-loader-job.yaml
```

### vLLM takes a long time to start (>3 min)

**Cause:** Model loading from EFS (expected ~1-2 min on first load per node)

**Note:** Unlike the EBS snapshot approach, EFS loads the model over the network. This is slower but enables:
- Scale-to-zero without losing the model
- Shared storage across all pods
- Simpler model updates (just re-run the loader job)

**Fix (if slower than expected):**
```bash
# Check EFS throughput mode
aws efs describe-file-systems --file-system-id $(terraform -chdir=terraform output -raw efs_filesystem_id)

# Should show: "ThroughputMode": "elastic"
```

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

## Next Steps

Once you have the basic setup running:

1. **Customize the model**: Edit `kubernetes/vllm/deployment.yaml` to use a different model
2. **Adjust scaling**: Modify the ScaledObject in `kubernetes/keda/` for different thresholds
3. **Add monitoring**: Deploy Prometheus + Grafana for production observability
4. **Enable CloudFront**: Run `make setup-cloudfront` for CDN + WAF protection

See [ARCHITECTURE.md](ARCHITECTURE.md) for deep dives into each component.
See [VLLM-OPTIMIZATION.md](VLLM-OPTIMIZATION.md) for the cold start optimization journey.
