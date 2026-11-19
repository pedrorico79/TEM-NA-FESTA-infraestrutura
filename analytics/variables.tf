variable "region" {
  description = "Região da camada analytics (a mesma do bucket bronze)."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = contains(["us-east-1", "us-west-2"], var.region)
    error_message = "region inválida: o laboratório só permite us-east-1 e us-west-2."
  }
}

variable "bronze_bucket_name" {
  description = "Nome do bucket bronze. Se null, bucket-bronze-<id-da-conta>-<region>."
  type        = string
  default     = null
}

variable "athena_bytes_scanned_cutoff" {
  description = "Limite de bytes escaneados por consulta no workgroup tnf."
  type        = number
  default     = 1073741824 # 1 GB

  validation {
    condition     = var.athena_bytes_scanned_cutoff >= 10485760
    error_message = "athena_bytes_scanned_cutoff precisa ser de pelo menos 10 MB (mínimo do Athena)."
  }
}

variable "dataset_envs" {
  description = "Ambientes cujos produtos do sistema podem ter coletas (valores da partição env)."
  type        = list(string)
  default     = ["dev", "prod"]
}
