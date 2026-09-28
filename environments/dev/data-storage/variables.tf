variable "aws_region" { type = string }
variable "project_name" { type = string }
variable "db_instance_class" { type = string }
variable "db_name" { type = string }
variable "db_master_username" { type = string }
variable "db_master_password" {
  type      = string
  sensitive = true
}

