resource "aws_ecr_repository" "api" {
  name                 = "ai-workloads-tube-demo/api"
  image_tag_mutability = "MUTABLE"
  image_scanning_configuration {
    scan_on_push = false
  }
}

resource "aws_ecr_repository" "frontend" {
  name                 = "ai-workloads-tube-demo/frontend"
  image_tag_mutability = "MUTABLE"
  image_scanning_configuration {
    scan_on_push = false
  }
}

resource "aws_ecr_repository" "vllm" {
  name                 = "ai-workloads-tube-demo/vllm"
  image_tag_mutability = "MUTABLE"
  image_scanning_configuration {
    scan_on_push = false
  }
}

output "ecr_repositories" {
  value = {
    api      = aws_ecr_repository.api.repository_url
    frontend = aws_ecr_repository.frontend.repository_url
    vllm     = aws_ecr_repository.vllm.repository_url
  }
}
