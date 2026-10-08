variable "aws_region" { type = string }
variable "project_name" { type = string }
variable "key_pair_name" { type = string }
variable "bastion_ssh_cidr" { type = string }
variable "instance_type_frontend" { type = string }
variable "frontend_repository_url" { type = string }
variable "frontend_repository_branch" { type = string }
variable "instance_type_backend" { type = string }
variable "instance_type_bastion" { type = string }
variable "backend_port" { type = number }
variable "backend_repository_url" { type = string }
variable "backend_repository_branch" { type = string }
variable "database_repository_url" { type = string }
variable "database_repository_branch" { type = string }
variable "db_instance_class" { type = string }
variable "db_name" { type = string }
variable "db_master_username" { type = string }
variable "db_master_password" {
  type      = string
  sensitive = true
}
variable "jwt_secret" {
  type      = string
  sensitive = true
}
variable "vpc_cidr" { type = string }
variable "enable_datalake" { type = bool }
