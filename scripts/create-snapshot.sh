#!/bin/bash
# Create EBS snapshot with vLLM container image pre-cached
# Model loading is handled via S3 streaming, not snapshot
set -e

SCRIPT_DIR=$(dirname "$0")
CONFIG_FILE="$SCRIPT_DIR/../.demo-config"

# Source demo config
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

AWS_REGION=${AWS_REGION:-$(aws configure get region)}
export AWS_DEFAULT_REGION="$AWS_REGION"
export AWS_PAGER=""

# Configuration
INSTANCE_TYPE=${INSTANCE_TYPE:-m5.large}
SNAPSHOT_SIZE=${SNAPSHOT_SIZE:-50}
FORCE_CREATE=${FORCE_CREATE:-false}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -f|--force) FORCE_CREATE=true; shift ;;
        *) shift ;;
    esac
done

# Get AWS account for ECR image path
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# The vLLM image we need to cache (from private ECR)
VLLM_IMAGE="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/ecr-public/deep-learning-containers/vllm:0.13-gpu-py312-ec2"
ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $*"
}

cleanup() {
    log "Cleaning up stack $1..."
    if aws cloudformation describe-stacks --stack-name "$1" &> /dev/null; then
        aws cloudformation delete-stack --stack-name "$1"
        aws cloudformation wait stack-delete-complete --stack-name "$1" 2>/dev/null || true
    fi
}

log "=== Creating EBS Snapshot with Pre-cached vLLM Image ==="
log "Image: $VLLM_IMAGE"
log "Region: $AWS_REGION"
log ""

# Check the current image digest in ECR
log "Checking ECR image details..."
IMAGE_DIGEST=$(aws ecr describe-images \
    --repository-name "ecr-public/deep-learning-containers/vllm" \
    --image-ids imageTag="0.13-gpu-py312-ec2" \
    --query 'imageDetails[0].imageDigest' --output text 2>/dev/null || echo "unknown")
IMAGE_MEDIA_TYPE=$(aws ecr describe-images \
    --repository-name "ecr-public/deep-learning-containers/vllm" \
    --image-ids imageTag="0.13-gpu-py312-ec2" \
    --query 'imageDetails[0].imageManifestMediaType' --output text 2>/dev/null || echo "unknown")
log "Image digest: $IMAGE_DIGEST"
log "Media type: $IMAGE_MEDIA_TYPE"
log ""

# Check for existing snapshot in config
if [ -n "$SNAPSHOT_ID" ] && [ "$FORCE_CREATE" != "true" ]; then
    log "Found existing SNAPSHOT_ID in .demo-config: $SNAPSHOT_ID"
    read -p "Create new snapshot anyway? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log "Using existing snapshot. Run 'make update-manifests' to regenerate configs."
        exit 0
    fi
fi

# Deploy EC2 instance via CloudFormation
RAND=$(od -An -N2 -i /dev/urandom | tr -d ' ' | cut -c1-4)
CFN_STACK_NAME="vllm-snapshot-$RAND"
log "[1/6] Deploying CloudFormation stack $CFN_STACK_NAME..."

aws cloudformation deploy \
    --stack-name "$CFN_STACK_NAME" \
    --template-file "$SCRIPT_DIR/ebs-snapshot-instance.yaml" \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameter-overrides \
        InstanceType="$INSTANCE_TYPE" \
        SnapshotSize="$SNAPSHOT_SIZE" > /dev/null

INSTANCE_ID=$(aws cloudformation describe-stacks --stack-name "$CFN_STACK_NAME" \
    --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue" --output text)
log "Instance launched: $INSTANCE_ID"

# Wait for SSM agent
log "[2/6] Waiting for SSM agent to come online..."
for i in {1..60}; do
    STATUS=$(aws ssm describe-instance-information \
        --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
        --query "InstanceInformationList[0].PingStatus" --output text 2>/dev/null || echo "None")
    if [ "$STATUS" = "Online" ]; then
        break
    fi
    sleep 5
done

if [ "$STATUS" != "Online" ]; then
    log "ERROR: SSM agent did not come online"
    cleanup "$CFN_STACK_NAME"
    exit 1
fi
log "SSM agent ready"

# Stop kubelet to prevent interference
log "[3/6] Stopping kubelet..."
CMDID=$(aws ssm send-command --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" --comment "Stop kubelet" \
    --parameters commands="apiclient exec admin sheltie systemctl stop kubelet" \
    --query "Command.CommandId" --output text)
aws ssm wait command-executed --command-id "$CMDID" --instance-id "$INSTANCE_ID" 2>/dev/null || true
sleep 5

# Pull vLLM container image from private ECR
log "[4/6] Pulling vLLM image (this may take 5-10 minutes)..."
log "     Image: $VLLM_IMAGE"

# Bottlerocket admin container doesn't have AWS CLI, so we get the ECR password locally
# and embed it directly in the command (the password is a JWT token, safe to pass inline)
ECR_PASSWORD=$(aws ecr get-login-password --region ${AWS_REGION})

# Create the pull command with password embedded
# Using a JSON file to avoid shell escaping issues
cat > /tmp/ssm-pull-ecr.json << EOFCMD
{
  "commands": [
    "apiclient exec admin sheltie ctr -a /run/containerd/containerd.sock -n k8s.io images pull --user 'AWS:${ECR_PASSWORD}' --label io.cri-containerd.image=managed ${VLLM_IMAGE}"
  ]
}
EOFCMD

CMDID=$(aws ssm send-command --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" --comment "Pull vLLM image from ECR" \
    --timeout-seconds 1200 \
    --parameters file:///tmp/ssm-pull-ecr.json \
    --query "Command.CommandId" --output text)

while true; do
    STATUS=$(aws ssm get-command-invocation --command-id "$CMDID" --instance-id "$INSTANCE_ID" \
        --query "Status" --output text 2>/dev/null || echo "Pending")
    case "$STATUS" in
        Success)
            break
            ;;
        Failed|TimedOut|Cancelled)
            ERROR=$(aws ssm get-command-invocation --command-id "$CMDID" --instance-id "$INSTANCE_ID" \
                --query "StandardErrorContent" --output text 2>/dev/null)
            OUTPUT=$(aws ssm get-command-invocation --command-id "$CMDID" --instance-id "$INSTANCE_ID" \
                --query "StandardOutputContent" --output text 2>/dev/null)
            log "ERROR: Image pull failed"
            log "STDERR: $ERROR"
            log "STDOUT: $OUTPUT"
            cleanup "$CFN_STACK_NAME"
            rm -f /tmp/ssm-pull-image.json
            exit 1
            ;;
    esac
    sleep 10
done
log "Image pulled successfully"
rm -f /tmp/ssm-pull-ecr.json

# Verify image is cached in containerd
log "Verifying image is cached..."
CMDID=$(aws ssm send-command --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" --comment "Verify image cached" \
    --parameters "commands=[\"apiclient exec admin sheltie ctr -a /run/containerd/containerd.sock -n k8s.io images ls | grep vllm\"]" \
    --query "Command.CommandId" --output text)
aws ssm wait command-executed --command-id "$CMDID" --instance-id "$INSTANCE_ID" 2>/dev/null || true

IMAGE_LIST=$(aws ssm get-command-invocation --command-id "$CMDID" --instance-id "$INSTANCE_ID" \
    --query "StandardOutputContent" --output text 2>/dev/null)
if [ -z "$IMAGE_LIST" ]; then
    log "WARNING: Could not verify image in containerd"
else
    log "Cached images:"
    echo "$IMAGE_LIST"
fi

# Stop instance before snapshot
log "[5/6] Stopping instance for snapshot..."
aws ec2 stop-instances --instance-ids "$INSTANCE_ID" > /dev/null
aws ec2 wait instance-stopped --instance-ids "$INSTANCE_ID"
log "Instance stopped"

# Create snapshot from data volume
log "[6/6] Creating EBS snapshot..."
DATA_VOLUME_ID=$(aws ec2 describe-instances --instance-id "$INSTANCE_ID" \
    --query "Reservations[0].Instances[0].BlockDeviceMappings[?DeviceName=='/dev/xvdb'].Ebs.VolumeId" --output text)

NEW_SNAPSHOT_ID=$(aws ec2 create-snapshot --volume-id "$DATA_VOLUME_ID" \
    --tag-specifications "ResourceType=snapshot,Tags=[{Key=Name,Value=vllm-container-image-cache},{Key=Project,Value=${PROJECT_NAME:-vllm-demo}},{Key=Image,Value=${VLLM_IMAGE}}]" \
    --description "vLLM container image pre-cached: ${VLLM_IMAGE}" \
    --query "SnapshotId" --output text)

log "Snapshot creating: $NEW_SNAPSHOT_ID"
log "Waiting for snapshot to complete (this may take a few minutes)..."

aws ec2 wait snapshot-completed --snapshot-ids "$NEW_SNAPSHOT_ID"
log "Snapshot ready: $NEW_SNAPSHOT_ID"

# Cleanup CloudFormation stack
cleanup "$CFN_STACK_NAME"

# Update .demo-config with new snapshot ID
if [ -f "$CONFIG_FILE" ]; then
    if grep -q "^SNAPSHOT_ID=" "$CONFIG_FILE"; then
        sed -i.bak "s/^SNAPSHOT_ID=.*/SNAPSHOT_ID=$NEW_SNAPSHOT_ID/" "$CONFIG_FILE"
        rm -f "$CONFIG_FILE.bak"
    else
        echo "SNAPSHOT_ID=$NEW_SNAPSHOT_ID" >> "$CONFIG_FILE"
    fi
    log "Updated .demo-config with SNAPSHOT_ID=$NEW_SNAPSHOT_ID"
fi

log ""
log "=== Done! ==="
log "Snapshot ID: $NEW_SNAPSHOT_ID"
log ""
log "Next steps:"
log "  1. Run 'make update-manifests' to regenerate Kubernetes configs"
log "  2. Run 'make deploy-apps' to deploy with the new snapshot"
