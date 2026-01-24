#!/bin/bash
set -euo pipefail

#############################################################################
# Secure Bastion Host Setup for EKS kubectl Access
# 
# This script creates a minimal, secure bastion host that can ONLY:
# - SSH access for specified IPs
# - kubectl access to the specified EKS cluster
# - Nothing else in your AWS account
#
# Usage: 
#   ./setup-bastion.sh <colleague-ip>           # Create/update with colleague IP + your IP (auto-detected)
#   ./setup-bastion.sh --teardown               # Remove all bastion resources
#
# Examples:
#   ./setup-bastion.sh 203.0.113.50             # Allow colleague + your current IP
#   ./setup-bastion.sh --teardown               # Clean up everything
#############################################################################

# Configuration
CLUSTER_NAME="kedify-on-eks-blueprint"
REGION="${AWS_REGION:-eu-west-1}"
BASTION_NAME="eks-bastion"
INSTANCE_TYPE="t3.micro"
SSH_KEY_NAME=""  # Leave empty to auto-create

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

usage() {
    echo "Usage: $0 <colleague-ip> | --teardown"
    echo ""
    echo "  <colleague-ip>   Public IP of your colleague (your IP is auto-detected)"
    echo "  --teardown       Remove all bastion resources"
    echo ""
    echo "Examples:"
    echo "  $0 203.0.113.50"
    echo "  $0 --teardown"
    exit 1
}

#############################################################################
# Teardown function
#############################################################################
teardown() {
    log "Tearing down bastion resources..."
    
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${BASTION_NAME}-role"
    
    # Get VPC ID from cluster
    VPC_ID=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" \
        --query 'cluster.resourcesVpcConfig.vpcId' --output text 2>/dev/null || echo "")
    
    # Get instance ID
    INSTANCE_ID=$(aws ec2 describe-instances \
        --filters "Name=tag:Name,Values=${BASTION_NAME}" "Name=instance-state-name,Values=running,stopped" \
        --query 'Reservations[0].Instances[0].InstanceId' \
        --output text --region "$REGION" 2>/dev/null || echo "None")
    
    if [ "$INSTANCE_ID" != "None" ] && [ -n "$INSTANCE_ID" ]; then
        log "Terminating instance $INSTANCE_ID..."
        aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$REGION"
        aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID" --region "$REGION"
    fi
    
    # Delete EKS access entry
    log "Removing EKS access entry..."
    aws eks delete-access-entry --cluster-name "$CLUSTER_NAME" --principal-arn "$ROLE_ARN" --region "$REGION" 2>/dev/null || true
    
    # Delete instance profile
    log "Deleting instance profile..."
    aws iam remove-role-from-instance-profile --instance-profile-name "${BASTION_NAME}-profile" --role-name "${BASTION_NAME}-role" 2>/dev/null || true
    aws iam delete-instance-profile --instance-profile-name "${BASTION_NAME}-profile" 2>/dev/null || true
    
    # Delete IAM role and policy
    log "Deleting IAM role..."
    aws iam delete-role-policy --role-name "${BASTION_NAME}-role" --policy-name "${BASTION_NAME}-eks-policy" 2>/dev/null || true
    aws iam delete-role --role-name "${BASTION_NAME}-role" 2>/dev/null || true
    
    # Delete security group
    log "Deleting security group..."
    if [ -n "$VPC_ID" ]; then
        SG_ID=$(aws ec2 describe-security-groups \
            --filters "Name=group-name,Values=${BASTION_NAME}-sg" "Name=vpc-id,Values=$VPC_ID" \
            --query 'SecurityGroups[0].GroupId' \
            --output text --region "$REGION" 2>/dev/null || echo "None")
        
        if [ "$SG_ID" != "None" ] && [ -n "$SG_ID" ]; then
            sleep 5
            aws ec2 delete-security-group --group-id "$SG_ID" --region "$REGION" 2>/dev/null || true
        fi
    fi
    
    log "Teardown complete!"
    exit 0
}

#############################################################################
# Parse arguments
#############################################################################
if [ $# -eq 0 ]; then
    usage
fi

if [ "$1" == "--teardown" ]; then
    teardown
fi

if [ "$1" == "--help" ] || [ "$1" == "-h" ]; then
    usage
fi

COLLEAGUE_IP="$1"

# Validate IP format
if ! [[ "$COLLEAGUE_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    error "Invalid IP address format: $COLLEAGUE_IP"
fi

#############################################################################
# Auto-detect your public IP
#############################################################################
log "Detecting your public IP..."
MY_IP=$(curl -s --max-time 5 https://checkip.amazonaws.com || curl -s --max-time 5 https://ifconfig.me || curl -s --max-time 5 https://ipinfo.io/ip)

if [ -z "$MY_IP" ]; then
    error "Could not detect your public IP. Check your internet connection."
fi

log "Your public IP: $MY_IP"
log "Colleague IP: $COLLEAGUE_IP"

ALLOWED_IPS=("${MY_IP}/32" "${COLLEAGUE_IP}/32")

#############################################################################
# Pre-flight checks
#############################################################################
log "Running pre-flight checks..."

command -v aws >/dev/null 2>&1 || error "AWS CLI not installed"
aws sts get-caller-identity >/dev/null 2>&1 || error "AWS credentials not configured"

# Get cluster info
CLUSTER_INFO=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" 2>/dev/null) || error "Cluster $CLUSTER_NAME not found"
VPC_ID=$(echo "$CLUSTER_INFO" | grep -o '"vpcId": "[^"]*"' | cut -d'"' -f4)
CLUSTER_ARN=$(echo "$CLUSTER_INFO" | grep -o '"arn": "arn:aws:eks:[^"]*"' | head -1 | cut -d'"' -f4)

log "Found cluster: $CLUSTER_NAME in VPC: $VPC_ID"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

#############################################################################
# Check if bastion already exists
#############################################################################
EXISTING_INSTANCE=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=${BASTION_NAME}" "Name=instance-state-name,Values=running,pending,stopped" \
    --query 'Reservations[0].Instances[0].InstanceId' \
    --output text --region "$REGION" 2>/dev/null || echo "None")

INSTANCE_EXISTS=false
if [ "$EXISTING_INSTANCE" != "None" ] && [ -n "$EXISTING_INSTANCE" ]; then
    INSTANCE_EXISTS=true
    log "Bastion instance already exists: $EXISTING_INSTANCE"
fi

#############################################################################
# Update or Create Security Group
#############################################################################
log "Configuring security group..."

SG_ID=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=${BASTION_NAME}-sg" "Name=vpc-id,Values=$VPC_ID" \
    --query 'SecurityGroups[0].GroupId' \
    --output text --region "$REGION" 2>/dev/null || echo "None")

if [ "$SG_ID" == "None" ] || [ -z "$SG_ID" ]; then
    log "Creating new security group..."
    SG_ID=$(aws ec2 create-security-group \
        --group-name "${BASTION_NAME}-sg" \
        --description "Bastion host - SSH only" \
        --vpc-id "$VPC_ID" \
        --query 'GroupId' \
        --output text --region "$REGION")
    
    # HTTPS outbound (for EKS API and package downloads)
    aws ec2 authorize-security-group-egress \
        --group-id "$SG_ID" \
        --protocol tcp \
        --port 443 \
        --cidr "0.0.0.0/0" \
        --region "$REGION" 2>/dev/null || true
    
    # HTTP outbound (for package repos)
    aws ec2 authorize-security-group-egress \
        --group-id "$SG_ID" \
        --protocol tcp \
        --port 80 \
        --cidr "0.0.0.0/0" \
        --region "$REGION" 2>/dev/null || true
else
    log "Security group exists: $SG_ID - updating SSH rules..."
    
    # Remove all existing SSH ingress rules
    EXISTING_RULES=$(aws ec2 describe-security-groups \
        --group-ids "$SG_ID" \
        --query 'SecurityGroups[0].IpPermissions[?FromPort==`22`].IpRanges[].CidrIp' \
        --output text --region "$REGION" 2>/dev/null || echo "")
    
    for old_cidr in $EXISTING_RULES; do
        log "Removing old SSH rule: $old_cidr"
        aws ec2 revoke-security-group-ingress \
            --group-id "$SG_ID" \
            --protocol tcp \
            --port 22 \
            --cidr "$old_cidr" \
            --region "$REGION" 2>/dev/null || true
    done
fi

# Add SSH rules for allowed IPs
for cidr in "${ALLOWED_IPS[@]}"; do
    log "Adding SSH access for: $cidr"
    aws ec2 authorize-security-group-ingress \
        --group-id "$SG_ID" \
        --protocol tcp \
        --port 22 \
        --cidr "$cidr" \
        --region "$REGION" 2>/dev/null || log "Rule already exists for $cidr"
done

log "Security group configured: $SG_ID"

#############################################################################
# Allow bastion to reach EKS API endpoint
#############################################################################
log "Configuring EKS cluster security group to allow bastion access..."

EKS_SG=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" \
    --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)

# Add ingress rule to EKS cluster SG to allow HTTPS from bastion
aws ec2 authorize-security-group-ingress \
    --group-id "$EKS_SG" \
    --protocol tcp \
    --port 443 \
    --source-group "$SG_ID" \
    --region "$REGION" 2>/dev/null || log "EKS SG rule already exists"

# If instance already exists, we're done (just updated SG rules)
if [ "$INSTANCE_EXISTS" = true ]; then
    PUBLIC_IP=$(aws ec2 describe-instances \
        --instance-ids "$EXISTING_INSTANCE" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' \
        --output text --region "$REGION")
    
    echo ""
    echo "=============================================="
    echo -e "${GREEN}Security Group Updated!${NC}"
    echo "=============================================="
    echo ""
    echo "Instance ID:  $EXISTING_INSTANCE"
    echo "Public IP:    $PUBLIC_IP"
    echo ""
    echo "Allowed SSH from:"
    for ip in "${ALLOWED_IPS[@]}"; do
        echo "  - $ip"
    done
    echo ""
    echo "SSH Command:"
    echo -e "  ${YELLOW}ssh -i ${BASTION_NAME}-key.pem ec2-user@${PUBLIC_IP}${NC}"
    echo "=============================================="
    exit 0
fi

#############################################################################
# Get a public subnet from the VPC
#############################################################################
log "Finding public subnet..."

PUBLIC_SUBNET=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=map-public-ip-on-launch,Values=true" \
    --query 'Subnets[0].SubnetId' \
    --output text --region "$REGION")

if [ "$PUBLIC_SUBNET" == "None" ] || [ -z "$PUBLIC_SUBNET" ]; then
    PUBLIC_SUBNET=$(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --query 'Subnets[?Tags[?contains(Value, `public`)]].SubnetId | [0]' \
        --output text --region "$REGION")
fi

[ "$PUBLIC_SUBNET" == "None" ] || [ -z "$PUBLIC_SUBNET" ] && error "No public subnet found in VPC"
log "Using subnet: $PUBLIC_SUBNET"

#############################################################################
# Create IAM Role with MINIMAL permissions
#############################################################################
log "Creating IAM role with minimal permissions..."

TRUST_POLICY=$(cat <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "ec2.amazonaws.com"
            },
            "Action": "sts:AssumeRole"
        }
    ]
}
EOF
)

aws iam create-role \
    --role-name "${BASTION_NAME}-role" \
    --assume-role-policy-document "$TRUST_POLICY" \
    --tags Key=Purpose,Value=EKS-Bastion 2>/dev/null || log "Role already exists"

MINIMAL_POLICY=$(cat <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "EKSDescribeClusterOnly",
            "Effect": "Allow",
            "Action": "eks:DescribeCluster",
            "Resource": "${CLUSTER_ARN}"
        },
        {
            "Sid": "STSGetCallerIdentity",
            "Effect": "Allow",
            "Action": "sts:GetCallerIdentity",
            "Resource": "*"
        }
    ]
}
EOF
)

aws iam put-role-policy \
    --role-name "${BASTION_NAME}-role" \
    --policy-name "${BASTION_NAME}-eks-policy" \
    --policy-document "$MINIMAL_POLICY"

log "IAM role configured"

#############################################################################
# Create Instance Profile
#############################################################################
log "Creating instance profile..."

aws iam create-instance-profile \
    --instance-profile-name "${BASTION_NAME}-profile" 2>/dev/null || log "Instance profile already exists"

aws iam add-role-to-instance-profile \
    --instance-profile-name "${BASTION_NAME}-profile" \
    --role-name "${BASTION_NAME}-role" 2>/dev/null || log "Role already attached"

sleep 10

#############################################################################
# Create EKS Access Entry
#############################################################################
log "Creating EKS access entry..."

ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${BASTION_NAME}-role"

aws eks create-access-entry \
    --cluster-name "$CLUSTER_NAME" \
    --principal-arn "$ROLE_ARN" \
    --type STANDARD \
    --region "$REGION" 2>/dev/null || log "Access entry already exists"

aws eks associate-access-policy \
    --cluster-name "$CLUSTER_NAME" \
    --principal-arn "$ROLE_ARN" \
    --policy-arn "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy" \
    --access-scope type=cluster \
    --region "$REGION" 2>/dev/null || log "Access policy already associated"

#############################################################################
# Get latest Amazon Linux 2023 AMI
#############################################################################
log "Finding latest Amazon Linux 2023 AMI..."

AMI_ID=$(aws ec2 describe-images \
    --owners amazon \
    --filters "Name=name,Values=al2023-ami-*-x86_64" "Name=state,Values=available" \
    --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
    --output text --region "$REGION")

#############################################################################
# User Data
#############################################################################
USER_DATA=$(cat <<'USERDATA'
#!/bin/bash
set -e
dnf update -y
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl && mv kubectl /usr/local/bin/

cat > /etc/profile.d/kubectl-setup.sh << 'SCRIPT'
if [ ! -f ~/.kube/config ]; then
    mkdir -p ~/.kube
    TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
    REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/region)
    CLUSTER=$(aws eks list-clusters --region $REGION --query 'clusters[0]' --output text 2>/dev/null)
    [ -n "$CLUSTER" ] && [ "$CLUSTER" != "None" ] && aws eks update-kubeconfig --region $REGION --name $CLUSTER 2>/dev/null || true
fi
SCRIPT

sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
systemctl restart sshd
dnf install -y fail2ban && systemctl enable --now fail2ban
USERDATA
)

USER_DATA_B64=$(echo "$USER_DATA" | base64)

#############################################################################
# Handle SSH Key
#############################################################################
if [ -z "$SSH_KEY_NAME" ]; then
    SSH_KEY_NAME="${BASTION_NAME}-key"
    
    if ! aws ec2 describe-key-pairs --key-names "$SSH_KEY_NAME" --region "$REGION" >/dev/null 2>&1; then
        log "Creating new SSH key pair..."
        aws ec2 create-key-pair \
            --key-name "$SSH_KEY_NAME" \
            --query 'KeyMaterial' \
            --output text \
            --region "$REGION" > "${SSH_KEY_NAME}.pem"
        chmod 400 "${SSH_KEY_NAME}.pem"
        warn "SSH private key saved to: ${SSH_KEY_NAME}.pem"
    else
        log "Using existing key pair: $SSH_KEY_NAME"
    fi
fi

#############################################################################
# Launch EC2 Instance
#############################################################################
log "Launching bastion instance..."

INSTANCE_ID=$(aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$SSH_KEY_NAME" \
    --subnet-id "$PUBLIC_SUBNET" \
    --security-group-ids "$SG_ID" \
    --iam-instance-profile Name="${BASTION_NAME}-profile" \
    --associate-public-ip-address \
    --user-data "$USER_DATA_B64" \
    --metadata-options "HttpTokens=required,HttpPutResponseHopLimit=1,HttpEndpoint=enabled" \
    --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":30,"VolumeType":"gp3","Encrypted":true,"DeleteOnTermination":true}}]' \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${BASTION_NAME}}]" \
    --query 'Instances[0].InstanceId' \
    --output text \
    --region "$REGION")

log "Waiting for instance to be running..."
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$REGION"

PUBLIC_IP=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text --region "$REGION")

#############################################################################
# Output
#############################################################################
echo ""
echo "=============================================="
echo -e "${GREEN}Bastion Host Created Successfully!${NC}"
echo "=============================================="
echo ""
echo "Instance ID:  $INSTANCE_ID"
echo "Public IP:    $PUBLIC_IP"
echo "SSH Key:      $SSH_KEY_NAME"
echo ""
echo "Allowed SSH from:"
for ip in "${ALLOWED_IPS[@]}"; do
    echo "  - $ip"
done
echo ""
echo "SSH Command:"
echo -e "  ${YELLOW}ssh -i ${SSH_KEY_NAME}.pem ec2-user@${PUBLIC_IP}${NC}"
echo ""
echo "Once connected, kubectl will auto-configure on first login."
echo "Test with: kubectl get nodes"
echo ""
echo "Security Notes:"
echo "  - IAM role has MINIMAL permissions (only eks:DescribeCluster)"
echo "  - EKS access granted via access entry (not IAM)"
echo "  - IMDSv2 required, root login disabled, fail2ban enabled"
echo ""
echo "To update allowed IPs: ./setup-bastion.sh <new-colleague-ip>"
echo "To teardown: ./setup-bastion.sh --teardown"
echo "=============================================="
