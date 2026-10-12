variable "name_prefix" {
  description = "Prefixo dos nomes dos recursos (<project_name>-<env>)."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR /21 da VPC; as subnets são derivadas dele (03, seção 5)."
  type        = string
}

variable "az_names" {
  description = "As duas AZs do ambiente, [AZ1, AZ2]. As subnets públicas e de banco usam as duas."
  type        = list(string)

  validation {
    condition     = length(var.az_names) == 2
    error_message = "network: az_names precisa ter exatamente 2 AZs (o ALB e o RDS exigem duas)."
  }
}

variable "az_count" {
  description = "Quantas AZs recebem subnets web e app (1 ou 2)."
  type        = number

  validation {
    condition     = contains([1, 2], var.az_count)
    error_message = "network: az_count deve ser 1 ou 2."
  }
}

variable "nat_mode" {
  description = "single (uma NAT, na AZ1) ou per_az (uma NAT por AZ ativa)."
  type        = string

  validation {
    condition     = contains(["single", "per_az"], var.nat_mode)
    error_message = "network: nat_mode deve ser \"single\" ou \"per_az\"."
  }
}
