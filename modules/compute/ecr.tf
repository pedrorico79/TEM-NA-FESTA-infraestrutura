# Amazon ECR Repositories for Docker Swarm Images

resource "aws_ecr_repository" "frontend" {
  name                 = "${var.project_name}-frontend"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name = "${var.project_name}-ecr-frontend"
  }
}

resource "aws_ecr_repository" "backend_som" {
  name                 = "${var.project_name}-backend-som"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name = "${var.project_name}-ecr-backend-som"
  }
}

resource "aws_ecr_repository" "notificacoes" {
  name                 = "${var.project_name}-notificacoes"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name = "${var.project_name}-ecr-notificacoes"
  }
}
