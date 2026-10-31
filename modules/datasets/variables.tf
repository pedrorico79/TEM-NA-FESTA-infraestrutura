variable "env" {
  description = "Ambiente (dev ou prod): vira a partição env da coleta."
  type        = string
}

variable "region" {
  description = "Região do ambiente (para o ARN do layer público)."
  type        = string
}

variable "bronze_bucket" {
  description = "Bucket bronze onde a coleta grava (10, seção 5)."
  type        = string
}

variable "api_url" {
  description = "URL da API do backend pelo ALB do ambiente, com /api/v1."
  type        = string
}

variable "dataset_ref" {
  description = "Tag do repositório do dataset empacotada na Lambda."
  type        = string
}

variable "lambda_zip_path" {
  description = "Pacote gerado por scripts/build-dataset-lambda.sh."
  type        = string
}

variable "schedule" {
  description = "Agenda do EventBridge; null não cria a regra (10, seção 4)."
  type        = string
  default     = null
}

variable "pandas_layer_version" {
  description = "Versão do layer público AWS SDK for pandas (Python 3.12)."
  type        = number
}

variable "reserved_concurrency" {
  description = "Concorrência reservada; -1 não reserva."
  type        = number
}

variable "secrets" {
  description = "Email e senha do usuário de coleta (dataset_api_email e dataset_api_password), vindos do secrets.env (10, seção 8)."
  type        = map(string)
  sensitive   = true
}
