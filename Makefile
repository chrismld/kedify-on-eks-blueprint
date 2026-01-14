.PHONY: setup-infra build-push-images deploy-apps run-demo dashboard enable-survey pick-winners teardown get-frontend-url generate-qr help

# Ensure /usr/local/bin is in PATH for kubectl and aws
export PATH := $(PATH):/usr/local/bin

help:
	@echo "🚇 AI Workloads Tube Demo - Available targets"
	@echo ""
	@echo "  make setup-infra         Create EKS cluster, Karpenter (KEDA disabled)"
	@echo "  make build-push-images   Build multi-arch images and push to ECR"
	@echo "  make deploy-apps         Deploy vLLM, API, frontend (no KEDA)"
	@echo "  make get-frontend-url    Get the frontend ALB URL"
	@echo "  make generate-qr         Generate QR code for audience"
	@echo "  make run-demo            Start k6 load gen and terminal dashboard"
	@echo "  make dashboard           Start terminal dashboard only"
	@echo "  make enable-survey       Switch to survey mode (T+28min)"
	@echo "  make pick-winners        Draw 2 random winners (T+29min)"
	@echo "  make teardown            Destroy all AWS resources"
	@echo ""
	@echo "Note: KEDA/Kedify is currently disabled. See SETUP-NOTES.md to re-enable."
	@echo ""

setup-infra:
	@echo "📦 Setting up EKS infrastructure..."
	cd terraform && terraform init
	cd terraform && terraform apply -auto-approve

build-push-images:
	@echo "🔨 Building and pushing images..."
	bash scripts/build-images.sh

deploy-apps:
	@echo "🚀 Deploying applications..."
	kubectl apply -k kubernetes/

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

teardown:
	@echo "💥 Destroying everything..."
	bash scripts/teardown.sh
	cd terraform && terraform destroy -auto-approve
