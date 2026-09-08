output "website_url" {
  description = "URL do Load Balancer"
  value       = module.tem_na_festa.website_url
}

output "bastion_public_ip" {
  description = "IP Público do Bastion Host para SSH"
  value       = module.tem_na_festa.bastion_public_ip
}

output "datalake_bronze_bucket_name" {
  description = "Bucket S3 - camada BRONZE do ambiente de análise de dados"
  value       = module.tem_na_festa.datalake_bronze_bucket_name
}

output "datalake_silver_bucket_name" {
  description = "Bucket S3 - camada SILVER do ambiente de análise de dados"
  value       = module.tem_na_festa.datalake_silver_bucket_name
}

output "datalake_gold_bucket_name" {
  description = "Bucket S3 - camada GOLD do ambiente de análise de dados"
  value       = module.tem_na_festa.datalake_gold_bucket_name
}

output "internal_backend_url" {
  description = "DNS do Load Balancer Interno (usar no Frontend para chamar a API)"
  value       = module.tem_na_festa.internal_backend_url
}
