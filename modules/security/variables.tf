variable "name_prefix" {
  description = "Prefixo dos nomes dos recursos (<project_name>-<env>)."
  type        = string
}

variable "vpc_id" {
  description = "VPC onde os security groups são criados."
  type        = string
}

variable "admin_ssh_cidrs" {
  description = "CIDRs IPv4 autorizados a fazer SSH no bastion; nunca 0.0.0.0/0 (T9)."
  type        = list(string)

  validation {
    condition     = alltrue([for c in var.admin_ssh_cidrs : can(cidrnetmask(c)) && !endswith(c, "/0")])
    error_message = "security: admin_ssh_cidrs aceita só blocos IPv4, e nunca 0.0.0.0/0 (SSH aberto para o mundo é proibido)."
  }
}
