#!/bin/bash
# Build EBS snapshot with vLLM image and Mistral 7B model pre-cached
set -e

SNAPSHOT_ID_FILE=".snapshot-id"
NODECLASS_TEMPLATE="kubernetes/karpenter/gpu-nodeclass.yaml.template"
NODECLASS_OUTPUT="kubernetes/karpenter/gpu-nodeclass.yaml"
SCRIPTPATH=$(dirname "$0")

# Configuration
AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-$(aws ec2 describe-availability-zones --output text --query 'AvailabilityZones[0].[RegionName]')}
INSTANCE_TYPE=${INSTANCE_TYPE:-m5.large}
SNAPSHOT_SIZE=${SNAPSHOT_SIZE:-150}
VLLM_IMAGE="docker.io/vllm/vllm-openai:v0.13.0"
MODEL_NAME="TheBloke/Mistral-7B-Instruct-v0.2-AWQ"

export AWS_DEFAULT_REGION
export AWS_PAGER=""

# Detect latest Bottlerocket version for EKS
detect_bottlerocket_version() {
    log "Detecting latest Bottlerocket version..."
    # Query SSM for available Bottlerocket versions and get the latest k8s version
    local latest_k8s=$(aws ssm get-parameters-by-path \
        --path "/aws/service/bottlerocket/aws-k8s-" \
        --query "Parameters[*].Name" --output text 2>/dev/null | \
        tr '\t' '\n' | grep -oE 'aws-k8s-[0-9]+\.[0-9]+' | sort -V | uniq | tail -1)
    
    if [ -z "$latest_k8s" ]; then
        log "Warning: Could not detect Bottlerocket version, using default 1.32"
        echo "1.32"
        return
    fi
    
    local version=$(echo "$latest_k8s" | grep -oE '[0-9]+\.[0-9]+')
    log "Detected Bottlerocket EKS version: $version"
    echo "$version"
}

# Get Bottlerocket AMI version string (e.g., v1.28.0)
get_bottlerocket_ami_version() {
    local k8s_version=$1
    local ami_id=$(aws ssm get-parameter \
        --name "/aws/service/bottlerocket/aws-k8s-${k8s_version}/x86_64/latest/image_id" \
        --query "Parameter.Value" --output text 2>/dev/null)
    
    if [ -z "$ami_id" ] || [ "$ami_id" = "None" ]; then
        echo "latest"
        return
    fi
    
    # Get the AMI name which contains the version
    local ami_name=$(aws ec2 describe-images --image-ids "$ami_id" \
        --query "Images[0].Name" --output text 2>/dev/null)
    
    # Extract version like v1.28.0 from name like bottlerocket-aws-k8s-1.32-x86_64-v1.28.0-...
    local br_version=$(echo "$ami_name" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    
    if [ -z "$br_version" ]; then
        echo "latest"
    else
        echo "$br_version"
    fi
}

AMI_ID=${AMI_ID:-/aws/service/bottlerocket/aws-k8s-1.32/x86_64/latest/image_id}

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $*"
}

cleanup() {
    log "Cleaning up stack $1..."
    if aws cloudformation describe-stacks --stack-name "$1" &> /dev/null; then
        aws cloudformation delete-stack --stack-name "$1"
    fi
}

# Generate nodeclass yaml with snapshot ID and Bottlerocket version
generate_nodeclass() {
    local snapshot_id=$1
    local k8s_version=$(detect_bottlerocket_version)
    local br_version=$(get_bottlerocket_ami_version "$k8s_version")
    
    log "Using Bottlerocket version: $br_version"
    sed -e "s/snap-0YOUR_SNAPSHOT_ID/$snapshot_id/" \
        -e "s/BR_VERSION_PLACEHOLDER/$br_version/" \
        "$NODECLASS_TEMPLATE" > "$NODECLASS_OUTPUT"
    log "Generated $NODECLASS_OUTPUT"
}

# Check for existing snapshot
if [ -f "$SNAPSHOT_ID_FILE" ]; then
    SNAPSHOT_ID=$(cat "$SNAPSHOT_ID_FILE")
    log "Found existing snapshot: $SNAPSHOT_ID"
    if [ -t 0 ]; then
        read -p "Create new snapshot? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            generate_nodeclass "$SNAPSHOT_ID"
            exit 0
        fi
    else
        generate_nodeclass "$SNAPSHOT_ID"
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

# [5/7] Download model DIRECTLY to /local (Bottlerocket's data volume)
log "[5/7] Downloading model $MODEL_NAME..."

cat > /tmp/download-model.json << 'EOF'
{
  "commands": [
    "apiclient exec admin sheltie ctr -a /run/containerd/containerd.sock -n k8s.io run --rm --net-host --env HF_HOME=/models/model-cache --mount type=bind,src=/local,dst=/models,options=rbind docker.io/vllm/vllm-openai:v0.13.0 model-dl python3 -c 'from huggingface_hub import snapshot_download; snapshot_download(\"TheBloke/Mistral-7B-Instruct-v0.2-AWQ\", cache_dir=\"/models/model-cache\")'"
  ]
}
EOF

CMDID=$(aws ssm send-command --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" --comment "Download model" \
    --timeout-seconds 1800 \
    --parameters file:///tmp/download-model.json \
    --query "Command.CommandId" --output text)

while true; do
    STATUS=$(aws ssm get-command-invocation --command-id "$CMDID" --instance-id "$INSTANCE_ID" --query "Status" --output text 2>/dev/null || echo "Pending")
    [[ "$STATUS" == "Success" ]] && break
    if [[ "$STATUS" == "Failed" || "$STATUS" == "TimedOut" ]]; then
        ERROR=$(aws ssm get-command-invocation --command-id "$CMDID" --instance-id "$INSTANCE_ID" --query "[StandardErrorContent,StandardOutputContent]" --output text 2>/dev/null)
        log "ERROR: $ERROR"
        cleanup "$CFN_STACK_NAME"
        exit 1
    fi
    sleep 10
done

rm -f /tmp/download-model.json
log "Model cached!"

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
generate_nodeclass "$SNAPSHOT_ID"

log "Done! Snapshot: $SNAPSHOT_ID"
log "Generated: $NODECLASS_OUTPUT"
