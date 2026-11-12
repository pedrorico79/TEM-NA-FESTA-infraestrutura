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
  description = "Nome do bucket bronze. Se null, bucket-bronze-<id-da-conta>-<region> (03, seção 3.6)."
  type        = string
  default     = null
}

variable "dataset_repo_url" {
  description = "Repositório público com os scripts de coleta (10, seção 3)."
  type        = string
  default     = "https://github.com/pedrorico79/TEM-NA-FESTA-dataset"

  validation {
    condition     = can(regex("^https://[^\\s]+$", var.dataset_repo_url))
    error_message = "dataset_repo_url deve ser uma URL https://."
  }
}

variable "dataset_ref" {
  description = "Tag do repositório do dataset empacotada na Lambda; nomes de branch são recusados (10, seção 7)."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.dataset_ref != ""
    error_message = "Preencha dataset_ref em analytics/terraform.tfvars com uma tag do repositório TEM-NA-FESTA-dataset (10, seção 7)."
  }

  validation {
    condition     = !contains(["main", "master", "develop", "head"], lower(var.dataset_ref))
    error_message = "dataset_ref = \"${var.dataset_ref}\" é uma branch: informe uma tag, para a coleta ser reproduzível."
  }
}

variable "lambda_zip_path" {
  description = "Pacote da Lambda gerado por scripts/build-dataset-lambda.sh. Se null, .infra/build/pof-trends-<dataset_ref>.zip."
  type        = string
  default     = null
}

variable "pof_trends_schedule" {
  description = "Agenda do EventBridge da coleta da base da EBD (UTC). null desliga a agenda."
  type        = string
  default     = "cron(0 12 ? * MON *)" # segunda-feira, 09:00 em São Paulo

  validation {
    condition     = var.pof_trends_schedule == null || can(regex("^(cron\\([^)]+\\)|rate\\([0-9]+ (minute|minutes|hour|hours|day|days)\\))$", var.pof_trends_schedule))
    error_message = "pof_trends_schedule deve ser uma expressão do EventBridge, como cron(0 12 ? * MON *) ou rate(7 days), ou null."
  }
}

variable "athena_bytes_scanned_cutoff" {
  description = "Limite de bytes escaneados por consulta no workgroup tnf (10, seção 6.2)."
  type        = number
  default     = 1073741824 # 1 GB

  validation {
    condition     = var.athena_bytes_scanned_cutoff >= 10485760
    error_message = "athena_bytes_scanned_cutoff precisa ser de pelo menos 10 MB (mínimo do Athena)."
  }
}

variable "pandas_layer_version" {
  description = "Versão do layer público AWS SDK for pandas para Python 3.12 na região (conferida na E10, 10 seção 13)."
  type        = number
  default     = 17
}

variable "lambda_reserved_concurrency" {
  description = "Concorrência reservada da Lambda (10, seção 4). -1 não reserva: o laboratório pode não permitir reservar."
  type        = number
  default     = 1
}

variable "dataset_envs" {
  description = "Ambientes cujos produtos do sistema podem ter coletas (valores da partição env)."
  type        = list(string)
  default     = ["dev", "prod"]
}
