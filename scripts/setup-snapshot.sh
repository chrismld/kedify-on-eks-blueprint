#!/bin/bash
# Build EBS snapshot with vLLM image and Mistral 7B model pre-cached
set -e

SNAPSHOT_ID_FILE=".snapshot-id"
NODECLASS_TEMPLATE="kubernetes/karpenter/gpu-nodeclass.yaml.template"
NODECLASS_OUTPUT="kubernetes/karpenter/gpu-nodeclass.yaml"
SCRIPTPATH=$(dirname "$0")

# Configuration
AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-$(aws ec2 describe-availability-zones --output text --query 'AvailabilityZones[0].[RegionName]')}
AMI_ID=${AMI_ID:-/aws/service/bottlerocket/aws-k8s-1.30/x86_64/latest/image_id}
INSTANCE_TYPE=${INSTANCE_TYPE:-m5.large}
SNAPSHOT_SIZE=${SNAPSHOT_SIZE:-150}
VLLM_IMAGE="docker.io/vllm/vllm-openai:latest"
MODEL_NAME="mistralai/Mistral-7B-Instruct-v0.2"

export AWS_DEFAULT_REGION
export AWS_PAGER=""

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $*"
}

cleanup() {
    log "Cleaning up stack $1..."
    if aws cloudformation describe-stacks --stack-name "$1" &> /dev/null; then
        aws cloudformation delete-stack --stack-name "$1"
    fi
}

# Check for existing snapshot
if [ -f "$SNAPSHOT_ID_FILE" ]; then
    SNAPSHOT_ID=$(cat "$SNAPSHOT_ID_FILE")
    log "Found existing snapshot: $SNAPSHOT_ID"
    if [ -t 0 ]; then
        read -p "Create new snapshot? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            sed "s/snap-0YOUR_SNAPSHOT_ID/$SNAPSHOT_ID/" "$NODECLASS_TEMPLATE" > "$NODECLASS_OUTPUT"
            log "Generated $NODECLASS_OUTPUT"
            exit 0
        fi
    else
        sed "s/snap-0YOUR_SNAPSHOT_ID/$SNAPSHOT_ID/" "$NODECLASS_TEMPLATE" > "$NODECLASS_OUTPUT"
        log "Generated $NODECLASS_OUTPUT"
        exit 0
    fi
fi

# Deploy EC2 instance
RAND=$(od -An -N2 -i /dev/urandom | tr -d ' ' | cut -c1-4)
CFN_STACK_NAME="vllm-snapshot-$RAND"
log "[1/7] Deploying CloudFormation stack $CFN_STACK_NAME..."

aws cloudformation deploy \
    --stack-name "$CFN_STACK_NAME" \
    --template-file "$SCRIPTPATH/ebs-snapshot-instance.yaml" \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameter-overrides \
        AmiID="$AMI_ID" \
        InstanceType="$INSTANCE_TYPE" \
        SnapshotSize="$SNAPSHOT_SIZE" > /dev/null

INSTANCE_ID=$(aws cloudformation describe-stacks --stack-name "$CFN_STACK_NAME" \
    --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue" --output text)

# Wait for SSM
log "[2/7] Waiting for SSM agent..."
while [[ $(aws ssm describe-instance-information --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
    --query "InstanceInformationList[0].PingStatus" --output text) != "Online" ]]; do
    sleep 5
done
log "SSM ready on $INSTANCE_ID"

# Stop kubelet
log "[3/7] Stopping kubelet..."
CMDID=$(aws ssm send-command --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" --comment "Stop kubelet" \
    --parameters commands="apiclient exec admin sheltie systemctl stop kubelet" \
    --query "Command.CommandId" --output text)
aws ssm wait command-executed --command-id "$CMDID" --instance-id "$INSTANCE_ID" > /dev/null

# Pull vLLM image
log "[4/7] Pulling vLLM image: $VLLM_IMAGE..."
sleep 5  # Give containerd time to stabilize after kubelet stop
CMDID=$(aws ssm send-command --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" --comment "Pull vLLM image" \
    --parameters commands="apiclient exec admin sheltie ctr -a /run/containerd/containerd.sock -n k8s.io images pull --label io.cri-containerd.image=managed $VLLM_IMAGE" \
    --query "Command.CommandId" --output text)

while true; do
    STATUS=$(aws ssm get-command-invocation --command-id "$CMDID" --instance-id "$INSTANCE_ID" \
        --query "Status" --output text 2>/dev/null || echo "Pending")
    [[ "$STATUS" == "Success" ]] && break
    if [[ "$STATUS" == "Failed" ]]; then
        ERROR=$(aws ssm get-command-invocation --command-id "$CMDID" --instance-id "$INSTANCE_ID" \
            --query "[StandardErrorContent,StandardOutputContent]" --output text 2>/dev/null)
        log "Image pull failed: $ERROR"
        cleanup "$CFN_STACK_NAME"
        exit 1
    fi
    sleep 5
done
log "Image pulled"

# Download model - use sheltie with ctr, write to /local which is writable
log "[5/7] Downloading model $MODEL_NAME (10-15 min)..."

cat > /tmp/download-model.json << 'EOFCMD'
{
  "commands": [
    "apiclient exec admin sheltie ctr -a /run/containerd/containerd.sock -n k8s.io run --rm --net-host --env HF_HOME=/cache --mount type=bind,src=/local,dst=/cache,options=rbind docker.io/vllm/vllm-openai:latest model-dl python3 -c 'from huggingface_hub import snapshot_download; snapshot_download(\"mistralai/Mistral-7B-Instruct-v0.2\", cache_dir=\"/cache/model-cache\")'"
  ]
}
EOFCMD

CMDID=$(aws ssm send-command --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" --comment "Download model" \
    --timeout-seconds 1800 \
    --parameters file:///tmp/download-model.json \
    --query "Command.CommandId" --output text)

while true; do
    STATUS=$(aws ssm get-command-invocation --command-id "$CMDID" --instance-id "$INSTANCE_ID" \
        --query "Status" --output text 2>/dev/null || echo "Pending")
    [[ "$STATUS" == "Success" ]] && break
    if [[ "$STATUS" == "Failed" || "$STATUS" == "TimedOut" ]]; then
        ERROR=$(aws ssm get-command-invocation --command-id "$CMDID" --instance-id "$INSTANCE_ID" \
            --query "[StandardErrorContent,StandardOutputContent]" --output text 2>/dev/null)
        log "Model download failed: $ERROR"
        cleanup "$CFN_STACK_NAME"
        exit 1
    fi
    sleep 10
done
log "Model downloaded"

# Stop instance
log "[6/7] Stopping instance..."
aws ec2 stop-instances --instance-ids "$INSTANCE_ID" > /dev/null
aws ec2 wait instance-stopped --instance-ids "$INSTANCE_ID"

# Create snapshot
log "[7/7] Creating snapshot..."
DATA_VOLUME_ID=$(aws ec2 describe-instances --instance-id "$INSTANCE_ID" \
    --query "Reservations[0].Instances[0].BlockDeviceMappings[?DeviceName=='/dev/xvdb'].Ebs.VolumeId" --output text)
SNAPSHOT_ID=$(aws ec2 create-snapshot --volume-id "$DATA_VOLUME_ID" \
    --tag-specifications 'ResourceType=snapshot,Tags=[{Key=Name,Value=vllm-mistral-7b}]' \
    --description "vLLM with Mistral 7B pre-cached" \
    --query "SnapshotId" --output text)

until aws ec2 wait snapshot-completed --snapshot-ids "$SNAPSHOT_ID" &> /dev/null; do
    sleep 5
done
log "Snapshot ready: $SNAPSHOT_ID"

# Cleanup
cleanup "$CFN_STACK_NAME"
rm -f /tmp/download-model.json

# Save and generate output
echo "$SNAPSHOT_ID" > "$SNAPSHOT_ID_FILE"
sed "s/snap-0YOUR_SNAPSHOT_ID/$SNAPSHOT_ID/" "$NODECLASS_TEMPLATE" > "$NODECLASS_OUTPUT"

log "Done! Snapshot: $SNAPSHOT_ID"
log "Generated: $NODECLASS_OUTPUT"
