output "website_url" {
  description = "URL do Load Balancer"
  value       = "http://${aws_lb.public.dns_name}"
}

output "bastion_public_ip" {
  description = "IP Público do Bastion Host para SSH"
  value       = aws_instance.bastion.public_ip
}

output "ecr_repositories" {
  description = "URLs dos repositórios ECR"
  value = {
    frontend     = aws_ecr_repository.frontend.repository_url
    backend_som  = aws_ecr_repository.backend_som.repository_url
    notificacoes = aws_ecr_repository.notificacoes.repository_url
  }
}

output "datalake_bronze_bucket_name" {
  description = "Bucket S3 - camada BRONZE do ambiente de análise de dados"
  value       = var.enable_datalake ? aws_s3_bucket.datalake_bronze[0].id : null
}

output "datalake_silver_bucket_name" {
  description = "Bucket S3 - camada SILVER do ambiente de análise de dados"
  value       = var.enable_datalake ? aws_s3_bucket.datalake_silver[0].id : null
}

output "datalake_gold_bucket_name" {
  description = "Bucket S3 - camada GOLD do ambiente de análise de dados"
  value       = var.enable_datalake ? aws_s3_bucket.datalake_gold[0].id : null
}
