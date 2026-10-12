variable "bucket_name" {
  description = "Bucket de artefatos do ambiente (tnf-<env>-artifacts-<conta>-<região>), criado pelo infra up."
  type        = string
}

variable "stack_env" {
  description = "Valores do stack.env, sem segredos (03, seção 5; 06, seção 4)."
  type        = map(string)
}

variable "node_dir" {
  description = "Caminho da pasta node/ do repositório."
  type        = string
}

variable "stacks_dir" {
  description = "Caminho da pasta stacks/ do repositório."
  type        = string
}

variable "ready_after" {
  description = "Valores de que o marcador READY depende além dos objetos (por exemplo, o endpoint do RDS)."
  type        = list(string)
  default     = []
}
