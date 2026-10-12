variable "region" {
  description = "Região do bucket de state."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = contains(["us-east-1", "us-west-2"], var.region)
    error_message = "region inválida: o laboratório só permite us-east-1 e us-west-2."
  }
}

variable "bronze_bucket_region" {
  description = "Região do bucket bronze (pode diferir de region)."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]$", var.bronze_bucket_region))
    error_message = "bronze_bucket_region deve ser um nome de região da AWS (por exemplo us-east-1)."
  }
}

variable "bronze_bucket_name" {
  description = "Nome do bucket bronze. Se null, bucket-bronze-<id-da-conta>-<bronze_bucket_region> (03, seção 3.6)."
  type        = string
  default     = null

  validation {
    condition     = var.bronze_bucket_name == null || can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.bronze_bucket_name))
    error_message = "bronze_bucket_name deve ser null ou um nome de bucket válido (3 a 63 caracteres: minúsculas, números, . e -)."
  }
}
