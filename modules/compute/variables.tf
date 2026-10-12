variable "env" {
  description = "Ambiente (dev ou prod)."
  type        = string
}

variable "name_prefix" {
  description = "Prefixo dos nomes (<project_name>-<env>)."
  type        = string
}

variable "region" {
  description = "Região da AWS do ambiente."
  type        = string
}

variable "nodes" {
  description = "Nós do Swarm calculados por modules/environment (03, seção 5): chave estável => grupo, hostname, az_index, IP fixo e papel de manager."
  type = map(object({
    group      = string
    index      = number
    hostname   = string
    az_index   = number
    private_ip = string
    manager    = bool
  }))
}

variable "subnet_ids" {
  description = "IDs das subnets por camada (public, web, app, db), na ordem das AZs."
  type        = map(list(string))
}

variable "security_group_ids" {
  description = "IDs dos security groups: alb, swarm_web, swarm_app, rds e bastion."
  type        = map(string)
}

variable "web_instance_type" {
  description = "Tipo das instâncias web."
  type        = string
}

variable "app_instance_type" {
  description = "Tipo das instâncias app."
  type        = string
}

variable "bastion_instance_type" {
  description = "Tipo da instância do bastion."
  type        = string
}

variable "bastion_enabled" {
  description = "Se false, não cria o bastion."
  type        = bool
}

variable "root_volume_size_gb" {
  description = "Tamanho do volume raiz (gp3), em GB."
  type        = number
}

variable "ami_id" {
  description = "AMI Ubuntu 24.04; se null, a mais recente da Canonical na criação do nó."
  type        = string
  default     = null
}

variable "artifacts_bucket" {
  description = "Bucket de artefatos do ambiente."
  type        = string
}

variable "bronze_bucket" {
  description = "Bucket bronze dos logs."
  type        = string
}

variable "bronze_region" {
  description = "Região do bucket bronze."
  type        = string
}

variable "ssh_private_key_path" {
  description = "Onde gravar a cópia local da chave privada (permissão 600)."
  type        = string
}

variable "node_dir" {
  description = "Caminho da pasta node/ do repositório (templates do Fluent Bit)."
  type        = string
}
