output "vpc_id" {
  value = aws_vpc.this.id
}

output "public_bastion_subnet_id" {
  value = aws_subnet.public_bastion.id
}

output "public_alb_subnet_id" {
  value = aws_subnet.public_alb.id
}

output "private_frontend_subnet_ids" {
  value = [aws_subnet.private_frontend_1a.id, aws_subnet.private_frontend_1b.id]
}

output "private_backend_subnet_ids" {
  value = [aws_subnet.private_backend_1a.id, aws_subnet.private_backend_1b.id]
}

output "private_db_subnet_ids" {
  value = [aws_subnet.private_db_1a.id, aws_subnet.private_db_1b.id]
}

output "rds_security_group_id" {
  value = aws_security_group.rds.id
}

output "efs_security_group_id" {
  value = aws_security_group.efs.id
}
