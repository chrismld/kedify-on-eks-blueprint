.PHONY: setup-infra build-push-images deploy-apps setup-cloudfront run-demo dashboard restart-demo enable-survey pick-winners teardown get-frontend-url generate-qr setup-model-s3 help

# Ensure /usr/local/bin is in PATH for kubectl and aws
export PATH := /usr/local/bin:$(PATH)

help:
	@echo "🚇 AI Workloads Tube Demo - Available targets"
	@echo ""
	@echo "  make setup-infra         Create EKS cluster, Karpenter, S3 bucket (KEDA disabled)"
	@echo "  make setup-model-s3      Upload model weights to S3"
	@echo "  make create-snapshot     Create EBS snapshot with pre-cached vLLM image"
	@echo "  make build-push-images   Build multi-arch images and push to ECR"
	@echo "  make update-manifests    Regenerate Kubernetes manifests from templates"
	@echo "  make deploy-apps         Deploy vLLM, API, frontend (no KEDA)"
	@echo "  make setup-cloudfront    Configure CloudFront with internal ALB (optional)"
	@echo "  make get-frontend-url    Get the frontend URL (ALB or CloudFront)"
	@echo "  make generate-qr         Generate QR code for audience"
	@echo "  make run-demo            Start k6 load gen and terminal dashboard"
	@echo "  make dashboard           Start terminal dashboard only"
	@echo "  make restart-demo        Restart demo to quiz mode"
	@echo "  make enable-survey       Switch to survey mode (auto-archives previous)"
	@echo "  make pick-winners        Draw 2 random winners"
	@echo "  make teardown            Destroy all AWS resources"
	@echo ""
	@echo "Note: KEDA/Kedify is currently disabled. See SETUP-NOTES.md to re-enable."
	@echo ""

setup-infra:
	@echo "📦 Setting up EKS infrastructure..."
	@echo ""
	@echo "This will create:"
	@echo "  - VPC and networking"
	@echo "  - EKS cluster with Karpenter"
	@echo "  - S3 bucket for model storage"
	@echo "  - ECR repositories"
	@echo "  - SOCI index for vLLM image (for fast container startup)"
	@echo ""
	@echo "Deploying Terraform infrastructure..."
	cd terraform && terraform init
	cd terraform && terraform apply -auto-approve
	@echo ""
	@echo "Generating SOCI index for vLLM image..."
	bash scripts/generate-soci-index.sh
	@echo ""
	@echo "✅ Infrastructure ready!"
	@echo ""
	@echo "Next steps:"
	@echo "  1. make setup-model-s3    # Upload model to S3"
	@echo "  2. make build-push-images # Build containers"
	@echo "  3. make deploy-apps       # Deploy everything"

setup-model-s3:
	@echo "📦 Uploading model to S3..."
	@echo ""
	@echo "This will:"
	@echo "  1. Download model from HuggingFace (~4GB)"
	@echo "  2. Upload to S3 bucket"
	@echo ""
	bash scripts/setup-model-s3.sh
	@echo ""
	@echo "📝 Updating vLLM deployment with S3 path..."
	bash scripts/update-manifests.sh

create-snapshot:
	@echo "📸 Creating EBS snapshot with pre-cached vLLM container image..."
	@echo ""
	@echo "This will:"
	@echo "  1. Launch a temporary Bottlerocket instance"
	@echo "  2. Pull the vLLM container image"
	@echo "  3. Create an EBS snapshot of the data volume"
	@echo "  4. Update .demo-config with the snapshot ID"
	@echo ""
	@echo "⏱️  This takes ~10-15 minutes"
	@echo ""
	bash scripts/create-snapshot.sh
	@echo ""
	@echo "📝 Regenerating manifests with snapshot ID..."
	bash scripts/update-manifests.sh

update-manifests:
	@echo "📝 Updating Kubernetes manifests from templates..."
	bash scripts/update-manifests.sh

build-push-images:
	@echo "🔨 Building and pushing images..."
	bash scripts/build-images.sh
	bash scripts/update-manifests.sh

deploy-apps:
	@echo "🚀 Deploying applications..."
	@echo ""
	@echo "Note: Model weights are streamed from S3 (no EFS needed)"
	@echo "      Make sure you've run 'make setup-model-s3' first"
	@echo ""
	kubectl apply -k kubernetes/
	@echo ""
	@echo "🎉 Deployment complete!"
	@echo ""
	@echo "Watch vLLM startup:"
	@echo "  kubectl logs -f deployment/vllm"

setup-cloudfront:
	@echo "☁️  Setting up CloudFront with VPC Origin..."
	@if ! grep -q "cloudfront_vpc_origin_id" terraform/terraform.tfvars || grep -q '^# cloudfront_vpc_origin_id' terraform/terraform.tfvars; then \
		echo "❌ Error: VPC Origin ID not set in terraform.tfvars"; \
		echo "   Run: bash scripts/setup-vpc-origin.sh first"; \
		exit 1; \
	fi
	cd terraform && terraform apply \
		-target=aws_cloudfront_cache_policy.frontend \
		-target=aws_cloudfront_origin_request_policy.frontend \
		-target=aws_cloudfront_distribution.frontend \
		-target=aws_wafv2_web_acl.cloudfront \
		-auto-approve
	@echo "✅ CloudFront setup complete!"
	@echo ""
	@echo "📋 CloudFront URL:"
	@cd terraform && terraform output cloudfront_url
	@echo ""
	@echo "💡 Your internal ALB is now accessible via CloudFront"

get-frontend-url:
	@echo "🔍 Getting frontend URL..."
	bash scripts/get-frontend-url.sh

generate-qr:
	@echo "📱 Generating QR code..."
	bash scripts/generate-qr.sh

run-demo:
	@echo "🎬 Starting demo..."
	bash scripts/run-demo.sh

dashboard:
	@echo "📊 Starting terminal dashboard..."
	bash scripts/dashboard.sh

restart-demo:
	@echo "🔄 Restarting demo to quiz mode..."
	bash scripts/restart-demo.sh

enable-survey:
	@echo "📝 Switching to survey mode..."
	bash scripts/enable-survey.sh

pick-winners:
	@echo "🎁 Drawing winners..."
	bash scripts/pick-winners.sh

teardown:
	@echo "💥 Destroying everything..."
	bash scripts/teardown.sh
	cd terraform && terraform destroy -auto-approve
