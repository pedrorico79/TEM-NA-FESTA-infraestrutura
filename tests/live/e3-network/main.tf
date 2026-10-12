# Raiz TEMPORÁRIA da E3 (09, E3; 08, seção 2): só a rede e os security
# groups, para validar no laboratório sem as variáveis sem padrão que a raiz
# envs/<env> completa exige (03, seção 3.8). O infra plan|up|down <env> usa
# esta raiz na E3, com os valores de envs/<env>/terraform.tfvars e o state em
# e3/<env>/terraform.tfstate. É apagada na E4a, quando envs/<env> passa a
# chamar os módulos.

variable "env" {
  description = "Ambiente: dev ou prod."
  type        = string

  validation {
    condition     = contains(["dev", "prod"], var.env)
    error_message = "env deve ser \"dev\" ou \"prod\"."
  }
}

variable "project_name" {
  description = "Nome do projeto."
  type        = string
  default     = "tem-na-festa"
}

variable "region" {
  description = "Região da AWS."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = contains(["us-east-1", "us-west-2"], var.region)
    error_message = "region inválida: o laboratório só permite us-east-1 e us-west-2."
  }
}

variable "vpc_cidr" {
  description = "CIDR /21 da VPC."
  type        = string
  default     = "10.0.0.0/21"

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr)) && endswith(var.vpc_cidr, "/21")
    error_message = "vpc_cidr precisa ser um bloco IPv4 /21."
  }
}

variable "az_names" {
  description = "AZs [AZ1, AZ2]; se null, as duas primeiras disponíveis na região."
  type        = list(string)
  default     = null
}

variable "az_count" {
  description = "AZs com subnets web e app (1 ou 2)."
  type        = number
  default     = 1
}

variable "nat_mode" {
  description = "single ou per_az."
  type        = string
  default     = "single"
}

variable "admin_ssh_cidrs" {
  description = "CIDRs autorizados a fazer SSH no bastion."
  type        = list(string)
  default     = []
}

data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  name_prefix = "${var.project_name}-${var.env}"
  az_names    = var.az_names != null ? slice(var.az_names, 0, 2) : slice(sort(data.aws_availability_zones.available.names), 0, 2)
}

module "network" {
  source = "../../../modules/network"

  name_prefix = local.name_prefix
  vpc_cidr    = var.vpc_cidr
  az_names    = local.az_names
  az_count    = var.az_count
  nat_mode    = var.nat_mode
}

module "security" {
  source = "../../../modules/security"

  name_prefix     = local.name_prefix
  vpc_id          = module.network.vpc_id
  admin_ssh_cidrs = var.admin_ssh_cidrs
}

output "az_names" {
  description = "AZs usadas."
  value       = local.az_names
}

output "vpc_id" {
  description = "ID da VPC."
  value       = module.network.vpc_id
}

output "subnet_cidrs" {
  description = "CIDRs das subnets por camada."
  value       = module.network.subnet_cidrs
}

output "nat_public_ips" {
  description = "Elastic IPs das NATs."
  value       = module.network.nat_public_ips
}

output "security_group_ids" {
  description = "IDs dos security groups."
  value       = module.security.security_group_ids
}
