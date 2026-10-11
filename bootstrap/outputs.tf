output "account_id" {
  description = "ID da conta da AWS."
  value       = local.account_id
}

output "state_bucket_name" {
  description = "Bucket do state do Terraform (tnf-tfstate-<conta>-<região>)."
  value       = aws_s3_bucket.state.bucket
}

output "state_bucket_region" {
  description = "Região do bucket do state."
  value       = var.region
}

output "bronze_bucket_name" {
  description = "Bucket bronze dos logs."
  value       = aws_s3_bucket.bronze.bucket
}

output "bronze_bucket_region" {
  description = "Região do bucket bronze."
  value       = var.bronze_bucket_region
}
