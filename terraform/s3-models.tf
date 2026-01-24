################################################################################
# S3 Bucket for Model Storage
################################################################################

resource "aws_s3_bucket" "models" {
  bucket = "${local.name}-models-${data.aws_caller_identity.current.account_id}"

  tags = merge(local.tags, {
    Name = "${local.name}-models"
  })
}

resource "aws_s3_bucket_public_access_block" "models" {
  bucket = aws_s3_bucket.models.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "models" {
  bucket = aws_s3_bucket.models.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "models" {
  bucket = aws_s3_bucket.models.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

################################################################################
# IAM for vLLM pods to access S3
################################################################################

module "vllm_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name = "${local.name}-vllm-irsa"

  role_policy_arns = {
    s3_access = aws_iam_policy.vllm_s3_access.arn
  }

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["default:vllm"]
    }
  }

  tags = local.tags
}

resource "aws_iam_policy" "vllm_s3_access" {
  name        = "${local.name}-vllm-s3-access"
  description = "Allow vLLM pods to read model weights from S3"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.models.arn,
          "${aws_s3_bucket.models.arn}/*"
        ]
      }
    ]
  })

  tags = local.tags
}

resource "kubernetes_service_account" "vllm" {
  metadata {
    name      = "vllm"
    namespace = "default"
    annotations = {
      "eks.amazonaws.com/role-arn" = module.vllm_irsa.iam_role_arn
    }
  }

  depends_on = [module.eks]
}

################################################################################
# Outputs
################################################################################

output "models_bucket_name" {
  description = "S3 bucket name for model storage"
  value       = aws_s3_bucket.models.id
}

output "models_bucket_arn" {
  description = "S3 bucket ARN for model storage"
  value       = aws_s3_bucket.models.arn
}

output "vllm_service_account_role_arn" {
  description = "IAM role ARN for vLLM service account"
  value       = module.vllm_irsa.iam_role_arn
}
