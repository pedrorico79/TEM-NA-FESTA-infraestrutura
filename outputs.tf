output "website_url" {
  description = "URL do Load Balancer"
  value       = "http://${aws_lb.public.dns_name}"
}

output "bastion_public_ip" {
  description = "IP Público do Bastion Host para SSH"
  value       = aws_instance.bastion.public_ip
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

output "internal_backend_url" {
  description = "DNS do Load Balancer Interno (usar no Frontend para chamar a API)"
  value       = "http://${aws_lb.internal.dns_name}"
}
