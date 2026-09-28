variable "project_name" { type = string }
variable "db_instance_class" { type = string }
variable "db_name" { type = string }
variable "db_master_username" { type = string }
variable "db_master_password" {
  type      = string
  sensitive = true
}
variable "private_db_subnet_ids" { type = list(string) }
variable "private_frontend_subnet_ids" { type = list(string) }
variable "rds_security_group_id" { type = string }
variable "efs_security_group_id" { type = string }
