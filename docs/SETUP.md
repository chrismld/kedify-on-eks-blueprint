# Step-by-Step Setup Guide

## Prerequisites

1. **AWS Account**
   - Permissions: EC2, EKS, IAM, S3
   - Enough Spot capacity in your region (check console)

2. **Local Tools**
   ```bash
   # macOS
   brew install terraform kubectl aws-cli docker docker-buildx k6 jq
   
   # Linux
   # Install from official websites: terraform.io, docker.com, etc.
   ```

3. **AWS Credentials**
   ```bash
   aws configure
   ```

4. **Docker buildx** (for multi-arch builds)
   ```bash
   docker buildx create --use
   ```

## Step 1: Generate Project (5 min)

```bash
bash create-project.sh /path/to/projects
cd /path/to/projects/kedify-on-eks-blueprint
```

## Step 2: Configure Terraform (2 min)

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars

# Edit region if desired
vim terraform/terraform.tfvars
```

## Step 3: Deploy Infrastructure (25-30 min)

```bash
make setup-infra
```

This runs:
- EKS cluster
- Karpenter controller
- Kedify KEDA + OTEL add-on
- ECR repositories

Wait for all pods to be running:
```bash
kubectl get pods -A
```

## Step 4: Build Images (10-15 min)

```bash
make build-push-images
```

This builds multi-arch images (amd64, arm64) and pushes to ECR.

## Step 5: Deploy Apps (5 min)

```bash
make deploy-apps
```

Verify:
```bash
kubectl get deployments
kubectl get pods
```

Wait for vLLM pod to be running (can take 2-3 minutes as Karpenter provisions GPU node):
```bash
kubectl logs -f deployment/vllm
```

## Step 6: Run Demo (30 min)

```bash
make run-demo
```

Open:
- **OTEL Scaler Metrics**: http://localhost:8080/metrics

Share QR code with audience. At T+28 min:

```bash
make enable-survey
```

At T+29 min:

```bash
make pick-winners
```

## Step 7: Cleanup (5 min)

```bash
make teardown
```

## Troubleshooting

See [docs/TROUBLESHOOTING.md](TROUBLESHOOTING.md)
