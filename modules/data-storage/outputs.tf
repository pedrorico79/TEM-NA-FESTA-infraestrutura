output "rds_endpoint" {
  value = aws_db_instance.this.endpoint
}

output "rds_port" {
  value = aws_db_instance.this.port
}

output "efs_id" {
  value = aws_efs_file_system.this.id
}
