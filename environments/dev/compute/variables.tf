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
variable "iam_instance_profile_name" { type = string }

