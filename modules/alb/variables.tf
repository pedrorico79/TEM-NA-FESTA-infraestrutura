variable "name_prefix" {
  description = "Prefixo dos nomes (<project_name>-<env>)."
  type        = string
}

variable "vpc_id" {
  description = "VPC do ambiente (para o target group)."
  type        = string
}

variable "subnet_ids" {
  description = "Subnets públicas das duas AZs (o ALB exige duas)."
  type        = list(string)
}

variable "security_group_id" {
  description = "Security group alb (80 de qualquer origem)."
  type        = string
}

variable "web_instance_ids" {
  description = "Nós web: chave estável (web-1, web-2...) => ID da instância. Todos entram no target group, pelo routing mesh do Swarm (02, seção 5)."
  type        = map(string)
}
