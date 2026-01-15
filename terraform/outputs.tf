output "configure_kubectl" {
  description = "Configure kubectl command"
  value       = "aws eks --region ${var.region} update-kubeconfig --name ${module.eks.cluster_name}"
}

output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "cloudfront_url" {
  description = "CloudFront URL for accessing the frontend"
  value       = "https://${aws_cloudfront_distribution.frontend.domain_name}"
}

output "internal_alb_dns" {
  description = "Internal ALB DNS name"
  value       = data.aws_lb.frontend_alb.dns_name
}
