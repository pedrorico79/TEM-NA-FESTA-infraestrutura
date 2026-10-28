# Raiz do ambiente: só repassa as variáveis ao módulo de composição
# (08, seções 2 e 3). Os valores ficam em terraform.tfvars; regras, padrões
# e mensagens de erro ficam em modules/environment (03). Este arquivo é igual
# em envs/dev e envs/prod (G4).
#
# As variáveis abaixo não têm validação nem padrão próprio: null faz valer o
# padrão do módulo. As quatro sem padrão (dockerhub_namespace e db_schema_*)
# ficam em branco no terraform.tfvars até existirem (03, seção 3.8).


variable "env" {
  description = "Ver modules/environment e 03."
  type        = string
}

variable "project_name" {
  description = "Ver modules/environment e 03."
  type        = string
  default     = null
}

variable "region" {
  description = "Ver modules/environment e 03."
  type        = string
  default     = null
}

variable "vpc_cidr" {
  description = "Ver modules/environment e 03."
  type        = string
  default     = null
}

variable "az_names" {
  description = "Ver modules/environment e 03."
  type        = list(string)
  default     = null
}

variable "az_count" {
  description = "Ver modules/environment e 03."
  type        = number
  default     = null
}

variable "nat_mode" {
  description = "Ver modules/environment e 03."
  type        = string
  default     = null
}

variable "web_node_count" {
  description = "Ver modules/environment e 03."
  type        = number
  default     = null
}

variable "app_node_count" {
  description = "Ver modules/environment e 03."
  type        = number
  default     = null
}

variable "manager_count" {
  description = "Ver modules/environment e 03."
  type        = number
  default     = null
}

variable "bastion_enabled" {
  description = "Ver modules/environment e 03."
  type        = bool
  default     = null
}

variable "ec2_instance_limit" {
  description = "Ver modules/environment e 03."
  type        = number
  default     = null
}

variable "web_instance_type" {
  description = "Ver modules/environment e 03."
  type        = string
  default     = null
}

variable "app_instance_type" {
  description = "Ver modules/environment e 03."
  type        = string
  default     = null
}

variable "bastion_instance_type" {
  description = "Ver modules/environment e 03."
  type        = string
  default     = null
}

variable "root_volume_size_gb" {
  description = "Ver modules/environment e 03."
  type        = number
  default     = null
}

variable "ami_id" {
  description = "Ver modules/environment e 03."
  type        = string
  default     = null
}

variable "service_replicas" {
  description = "Ver modules/environment e 03."
  type = object({
    frontend  = number
    backend   = number
    messaging = number
  })
  default = null
}

variable "image_tags" {
  description = "Ver modules/environment e 03."
  type = object({
    frontend  = string
    backend   = string
    messaging = string
  })
  default = null
}

variable "dockerhub_namespace" {
  description = "Ver modules/environment e 03."
  type        = string
}

variable "messaging_port" {
  description = "Ver modules/environment e 03."
  type        = number
  default     = null
}

variable "db_instance_class" {
  description = "Ver modules/environment e 03."
  type        = string
  default     = null
}

variable "db_allocated_storage_gb" {
  description = "Ver modules/environment e 03."
  type        = number
  default     = null
}

variable "db_multi_az" {
  description = "Ver modules/environment e 03."
  type        = bool
  default     = null
}

variable "db_engine_version" {
  description = "Ver modules/environment e 03."
  type        = string
  default     = null
}

variable "db_name" {
  description = "Ver modules/environment e 03."
  type        = string
  default     = null
}

variable "db_master_username" {
  description = "Ver modules/environment e 03."
  type        = string
  default     = null
}

variable "db_snapshot_identifier" {
  description = "Ver modules/environment e 03."
  type        = string
  default     = null
}

variable "db_schema_repo_url" {
  description = "Ver modules/environment e 03."
  type        = string
}

variable "db_schema_ref" {
  description = "Ver modules/environment e 03."
  type        = string
}

variable "db_schema_path" {
  description = "Ver modules/environment e 03."
  type        = string
}

variable "messaging_db_name" {
  description = "Ver modules/environment e 03."
  type        = string
  default     = null
}

variable "messaging_db_schema_repo_url" {
  description = "Ver modules/environment e 03."
  type        = string
  default     = null
}

variable "messaging_db_schema_ref" {
  description = "Ver modules/environment e 03."
  type        = string
  default     = null
}

variable "messaging_db_schema_path" {
  description = "Ver modules/environment e 03."
  type        = string
  default     = null
}

variable "admin_ssh_cidrs" {
  description = "Ver modules/environment e 03."
  type        = list(string)
  default     = null
}

variable "ssh_private_key_path" {
  description = "Ver modules/environment e 03."
  type        = string
  default     = null
}

variable "bronze_bucket_name" {
  description = "Ver modules/environment e 03."
  type        = string
  default     = null
}

variable "bronze_bucket_region" {
  description = "Ver modules/environment e 03."
  type        = string
  default     = null
}

variable "messaging_secrets" {
  description = "Ver modules/environment e 03."
  type        = map(string)
  default     = null
  sensitive   = true
}

module "environment" {
  source = "../../modules/environment"

  env                          = var.env
  project_name                 = var.project_name
  region                       = var.region
  vpc_cidr                     = var.vpc_cidr
  az_names                     = var.az_names
  az_count                     = var.az_count
  nat_mode                     = var.nat_mode
  web_node_count               = var.web_node_count
  app_node_count               = var.app_node_count
  manager_count                = var.manager_count
  bastion_enabled              = var.bastion_enabled
  ec2_instance_limit           = var.ec2_instance_limit
  web_instance_type            = var.web_instance_type
  app_instance_type            = var.app_instance_type
  bastion_instance_type        = var.bastion_instance_type
  root_volume_size_gb          = var.root_volume_size_gb
  ami_id                       = var.ami_id
  service_replicas             = var.service_replicas
  image_tags                   = var.image_tags
  dockerhub_namespace          = var.dockerhub_namespace
  messaging_port               = var.messaging_port
  db_instance_class            = var.db_instance_class
  db_allocated_storage_gb      = var.db_allocated_storage_gb
  db_multi_az                  = var.db_multi_az
  db_engine_version            = var.db_engine_version
  db_name                      = var.db_name
  db_master_username           = var.db_master_username
  db_snapshot_identifier       = var.db_snapshot_identifier
  db_schema_repo_url           = var.db_schema_repo_url
  db_schema_ref                = var.db_schema_ref
  db_schema_path               = var.db_schema_path
  messaging_db_name            = var.messaging_db_name
  messaging_db_schema_repo_url = var.messaging_db_schema_repo_url
  messaging_db_schema_ref      = var.messaging_db_schema_ref
  messaging_db_schema_path     = var.messaging_db_schema_path
  admin_ssh_cidrs              = var.admin_ssh_cidrs
  ssh_private_key_path         = var.ssh_private_key_path
  bronze_bucket_name           = var.bronze_bucket_name
  bronze_bucket_region         = var.bronze_bucket_region
  messaging_secrets            = var.messaging_secrets
}

output "name_prefix" {
  description = "Prefixo dos nomes de recursos."
  value       = module.environment.name_prefix
}

output "instance_count" {
  description = "Instâncias EC2 planejadas."
  value       = module.environment.instance_count
}

output "expected_nodes" {
  description = "Nós do Swarm esperados (EXPECTED_NODES)."
  value       = module.environment.expected_nodes
}

output "nodes" {
  description = "Nós do Swarm com AZ, subnet, IP fixo e papel."
  value       = module.environment.nodes
}

output "subnet_cidrs" {
  description = "CIDRs das subnets por camada."
  value       = module.environment.subnet_cidrs
}

output "artifacts_bucket" {
  description = "Bucket de artefatos do ambiente."
  value       = module.environment.artifacts_bucket
}

output "bastion_public_ip" {
  description = "IP público do bastion."
  value       = module.environment.bastion_public_ip
}

output "bastion_security_group_id" {
  description = "Security group do bastion."
  value       = module.environment.bastion_security_group_id
}

output "admin_ssh_cidrs" {
  description = "CIDRs autorizados a fazer SSH no bastion."
  value       = module.environment.admin_ssh_cidrs
}

output "node_ips" {
  description = "Hostname => IP privado dos nós do Swarm."
  value       = module.environment.node_ips
}

output "ssh_public_key" {
  description = "Chave pública do ambiente."
  value       = module.environment.ssh_public_key
}

output "ssh_private_key" {
  description = "Chave privada do ambiente (sensível), usada só pelo infra access."
  value       = module.environment.ssh_private_key
  sensitive   = true
}

output "alb_dns_name" {
  description = "Nome DNS do ALB (o endereço do sistema)."
  value       = module.environment.alb_dns_name
}
