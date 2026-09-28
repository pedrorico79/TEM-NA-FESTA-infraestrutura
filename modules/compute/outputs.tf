output "bastion_public_ip" {
  value = aws_instance.bastion.public_ip
}

output "website_url" {
  value = aws_lb.public.dns_name
}

output "frontend_manager_private_ip" {
  value = aws_instance.frontend_1.private_ip
}

output "ecr_frontend_url" {
  value = aws_ecr_repository.frontend.repository_url
}

output "ecr_backend_url" {
  value = aws_ecr_repository.backend_som.repository_url
}

output "ecr_notificacoes_url" {
  value = aws_ecr_repository.notificacoes.repository_url
}
