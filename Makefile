.PHONY: setup-infra build-push-images deploy-apps setup-cloudfront run-demo dashboard restart-demo enable-survey pick-winners teardown get-frontend-url generate-qr optimize-vllm help

# Ensure /usr/local/bin is in PATH for kubectl and aws
export PATH := /usr/local/bin:$(PATH)

help:
	@echo "🚇 AI Workloads Tube Demo - Available targets"
	@echo ""
	@echo "  make setup-infra         Create EKS cluster, Karpenter (KEDA disabled)"
	@echo "  make build-push-images   Build multi-arch images and push to ECR"
	@echo "  make deploy-apps         Deploy vLLM, API, frontend (no KEDA)"
	@echo "  make optimize-vllm       Build custom AMI and deploy optimized vLLM (existing cluster)"
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
	@echo "Note: vLLM optimization (snapshot creation) will be done separately"
	@echo "Run 'make optimize-vllm' after infrastructure is ready"
	@echo ""
	@echo "Deploying Terraform infrastructure..."
	cd terraform && terraform init
	cd terraform && terraform apply \
		-target=module.vpc \
		-target=module.eks \
		-target=module.aws_ebs_csi_pod_identity \
		-target=module.aws_efs_csi_pod_identity \
		-target=aws_efs_file_system.models \
		-target=aws_security_group.efs \
		-target=aws_efs_mount_target.models \
		-target=kubernetes_storage_class_v1.gp3 \
		-target=aws_iam_role.aws_load_balancer_controller \
		-target=aws_iam_policy.aws_load_balancer_controller \
		-target=aws_iam_role_policy_attachment.aws_load_balancer_controller \
		-target=helm_release.aws_load_balancer_controller \
		-target=helm_release.metrics_server \
		-target=module.karpenter \
		-target=helm_release.karpenter \
		-target=kubectl_manifest.karpenter_node_class \
		-target=kubectl_manifest.karpenter_node_pool \
		-target=aws_ecr_repository.api \
		-target=aws_ecr_repository.frontend \
		-target=aws_ecr_repository.vllm \
		-auto-approve

build-push-images:
	@echo "🔨 Building and pushing images..."
	bash scripts/build-images.sh
	bash scripts/update-manifests.sh

deploy-apps:
	@echo "🚀 Deploying applications..."
	kubectl apply -k kubernetes/
	@echo ""
	@echo "📦 Checking if model needs to be loaded to EFS..."
	@if ! kubectl get job model-loader -o name 2>/dev/null | grep -q model-loader; then \
		echo "🔄 Starting model loader job (first-time setup, ~3-5 min)..."; \
		kubectl apply -f kubernetes/efs/model-loader-job.yaml; \
		echo "⏳ Waiting for model download to complete..."; \
		kubectl wait --for=condition=complete job/model-loader --timeout=600s || \
			(echo "❌ Model loader failed. Check logs: kubectl logs job/model-loader" && exit 1); \
		echo "✅ Model loaded to EFS!"; \
	else \
		echo "✅ Model already loaded (job exists)"; \
	fi
	@echo ""
	@echo "🎉 Deployment complete!"

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

optimize-vllm:
	@echo "⚡ Optimizing vLLM deployment (container image caching)..."
	@echo ""
	@echo "This will:"
	@echo "  1. Build EBS snapshot with vLLM container image pre-cached (~10-15 min)"
	@echo "  2. Deploy optimized GPU NodeClass"
	@echo "  3. Redeploy vLLM pods"
	@echo ""
	@echo "Note: Model weights are stored in EFS (shared storage)."
	@echo "      This snapshot only caches the container image for faster pulls."
	@echo ""
	@read -p "Continue? (y/N): " -n 1 -r; \
	echo; \
	if [[ $$REPLY =~ ^[Yy]$$ ]]; then \
		bash scripts/setup-snapshot.sh && \
		kubectl apply -f kubernetes/karpenter/gpu-nodeclass.yaml && \
		kubectl apply -f kubernetes/karpenter/gpu-nodepool.yaml && \
		kubectl rollout restart deployment/vllm && \
		echo "" && \
		echo "✅ Optimization deployed!" && \
		echo "" && \
		echo "Expected cold start: ~1-2 min (EFS model loading)" && \
		echo "Container image pull: ~10s (from EBS cache)" && \
		echo "Test with: kubectl scale deployment vllm --replicas=5"; \
	fi

teardown:
	@echo "💥 Destroying everything..."
	bash scripts/teardown.sh
	cd terraform && terraform destroy -auto-approve
