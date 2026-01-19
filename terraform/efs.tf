################################################################################
# EFS for Shared Model Storage
################################################################################

resource "aws_efs_file_system" "models" {
  creation_token   = "${local.name}-models"
  performance_mode = "generalPurpose"
  throughput_mode  = "elastic"
  encrypted        = true

  tags = merge(local.tags, {
    Name = "${local.name}-models"
  })
}

resource "aws_security_group" "efs" {
  name        = "${local.name}-efs"
  description = "Allow NFS traffic from EKS nodes"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "NFS from EKS nodes"
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [module.eks.node_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, {
    Name = "${local.name}-efs"
  })
}

resource "aws_efs_mount_target" "models" {
  count           = length(module.vpc.private_subnets)
  file_system_id  = aws_efs_file_system.models.id
  subnet_id       = module.vpc.private_subnets[count.index]
  security_groups = [aws_security_group.efs.id]
}

################################################################################
# EFS CSI Driver
################################################################################

module "aws_efs_csi_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "2.2.1"

  name                      = "aws-efs-csi"
  attach_aws_efs_csi_policy = true

  tags = local.tags
}
