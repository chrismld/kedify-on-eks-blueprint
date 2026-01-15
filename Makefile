.PHONY: setup-infra build-push-images deploy-apps setup-cloudfront run-demo dashboard enable-survey pick-winners teardown get-frontend-url generate-qr help

# Ensure /usr/local/bin is in PATH for kubectl and aws
export PATH := $(PATH):/usr/local/bin

help:
	@echo "🚇 AI Workloads Tube Demo - Available targets"
	@echo ""
	@echo "  make setup-infra         Create EKS cluster, Karpenter (KEDA disabled)"
	@echo "  make build-push-images   Build multi-arch images and push to ECR"
	@echo "  make deploy-apps         Deploy vLLM, API, frontend (no KEDA)"
	@echo "  make setup-cloudfront    Configure CloudFront with internal ALB (optional)"
	@echo "  make get-frontend-url    Get the frontend URL (ALB or CloudFront)"
	@echo "  make generate-qr         Generate QR code for audience"
	@echo "  make run-demo            Start k6 load gen and terminal dashboard"
	@echo "  make dashboard           Start terminal dashboard only"
	@echo "  make enable-survey       Switch to survey mode (T+28min)"
	@echo "  make pick-winners        Draw 2 random winners (T+29min)"
	@echo "  make list-sessions       List all sessions with response counts"
	@echo "  make teardown            Destroy all AWS resources"
	@echo ""
	@echo "Session Management (for multiple sessions):"
	@echo "  ./scripts/set-session.sh <code>      Set session code before demo"
	@echo "  ./scripts/enable-survey.sh <code>    Enable survey with session code"
	@echo "  ./scripts/pick-winners.sh <code>     Pick winners for specific session"
	@echo "  ./scripts/list-sessions.sh           List all sessions"
	@echo "  ./scripts/clear-session.sh <code>    Clear all data for a session"
	@echo ""
	@echo "Note: KEDA/Kedify is currently disabled. See SETUP-NOTES.md to re-enable."
	@echo ""

setup-infra:
	@echo "📦 Setting up EKS infrastructure..."
	cd terraform && terraform init
	cd terraform && terraform apply \
		-target=module.vpc \
		-target=module.eks \
		-target=module.aws_ebs_csi_pod_identity \
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

deploy-apps:
	@echo "🚀 Deploying applications..."
	kubectl apply -k kubernetes/

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

enable-survey:
	@echo "📝 Switching to survey mode..."
	bash scripts/enable-survey.sh

pick-winners:
	@echo "🎁 Drawing winners..."
	bash scripts/pick-winners.sh

list-sessions:
	@echo "📋 Listing all sessions..."
	bash scripts/list-sessions.sh

teardown:
	@echo "💥 Destroying everything..."
	bash scripts/teardown.sh
	cd terraform && terraform destroy -auto-approve
