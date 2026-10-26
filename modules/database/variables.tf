variable "name_prefix" {
  description = "Prefixo dos nomes (<project_name>-<env>)."
  type        = string
}

variable "subnet_ids" {
  description = "Subnets de banco (duas AZs)."
  type        = list(string)
}

variable "security_group_id" {
  description = "Security group rds (3306 só do swarm-app)."
  type        = string
}

variable "engine_version" {
  description = "Versão principal do MySQL."
  type        = string
}

variable "instance_class" {
  description = "Classe da instância do RDS."
  type        = string
}

variable "allocated_storage_gb" {
  description = "Armazenamento do RDS, em GB."
  type        = number
}

variable "multi_az" {
  description = "RDS Multi-AZ."
  type        = bool
}

variable "db_name" {
  description = "Nome do schema da aplicação; ignorado ao restaurar de snapshot."
  type        = string
}

variable "master_username" {
  description = "Usuário administrador do RDS."
  type        = string
}

variable "master_password" {
  description = "Senha do administrador, gerada pelo módulo secrets."
  type        = string
  sensitive   = true
}

variable "snapshot_identifier" {
  description = "Snapshot de origem; só vale na criação do RDS."
  type        = string
  default     = null
}
