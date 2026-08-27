variable "aws_region" {
  description = "Região AWS onde a stack será provisionada."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Prefixo usado no nome de todos os recursos."
  type        = string
  default     = "tem-na-festa"
}

variable "key_pair_name" {
  description = "Key Pair já existente na conta, usada para SSH nas instâncias."
  type        = string
}

variable "bastion_ssh_cidr" {
  description = "CIDR de origem liberado para SSH no Bastion. Para produção, restrinja ao seu IP (ex.: 203.0.113.10/32)."
  type        = string
  default     = "0.0.0.0/0"
}

variable "instance_type_frontend" {
  description = "Tipo de instância EC2 do Frontend."
  type        = string
  default     = "t3.micro"
}

variable "instance_type_backend" {
  description = "Tipo de instância EC2 do Backend."
  type        = string
  default     = "t3.micro"
}

variable "instance_type_bastion" {
  description = "Tipo de instância EC2 do Bastion."
  type        = string
  default     = "t3.micro"
}

variable "backend_port" {
  description = "Porta em que a aplicação backend (Spring Boot) escuta."
  type        = number
  default     = 8080
}

variable "db_instance_class" {
  description = "Classe de instância do RDS."
  type        = string
  default     = "db.t3.micro"
}

variable "db_name" {
  description = "Nome do banco de dados MySQL."
  type        = string
  default     = "temnafesta"
}

variable "db_master_username" {
  description = "Usuário master do RDS."
  type        = string
  default     = "admin"
}

variable "db_master_password" {
  description = "Senha do usuário master do RDS (mínimo 8 caracteres)."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.db_master_password) >= 8
    error_message = "A senha do RDS deve ter pelo menos 8 caracteres."
  }
}

variable "vpc_cidr" {
  description = "CIDR block da VPC."
  type        = string
  default     = "10.0.0.0/24"
}
