# Segredos do ambiente (05, A1 e A2): valores gerados pelo Terraform e os
# manuais (messaging_secrets), gravados como parâmetros SecureString do SSM
# em /tnf/<env>/secrets/<nome>. O líder do Swarm os lê e cria os segredos
# Docker (04, seção 7, passo 5). Removidos no destroy, sem sobras.

locals {
  # Tamanhos fixos (05, A1): só letras e dígitos, sem quebra de linha.
  generated = {
    db_admin_password = 32
    db_password       = 32
    rabbitmq_password = 32
    messaging_api_key = 48
    jwt_secret        = 64
  }

  # Nomes de usuário não são segredos aleatórios (05, A1), mas seguem o mesmo
  # caminho para o líder ler tudo de /tnf/<env>/secrets/.
  fixed = {
    rabbitmq_user = "tnf_rabbit"
  }

  prefix = "/tnf/${var.env}/secrets"
}

resource "random_password" "this" {
  for_each = local.generated

  length  = each.value
  special = false
  upper   = true
  lower   = true
  numeric = true
}

resource "aws_ssm_parameter" "generated" {
  for_each = local.generated

  name        = "${local.prefix}/${each.key}"
  description = "Segredo gerado ${each.key} do ambiente ${var.env}"
  type        = "SecureString"
  value       = random_password.this[each.key].result
}

resource "aws_ssm_parameter" "fixed" {
  for_each = local.fixed

  name        = "${local.prefix}/${each.key}"
  description = "Valor fixo ${each.key} do ambiente ${var.env}"
  type        = "SecureString"
  value       = each.value
}

# Segredos manuais: só existem com a mensageria ligada (05, A5).
resource "aws_ssm_parameter" "manual" {
  for_each = nonsensitive(toset(keys(var.messaging_secrets)))

  name        = "${local.prefix}/${each.key}"
  description = "Segredo manual ${each.key} do ambiente ${var.env}"
  type        = "SecureString"
  value       = var.messaging_secrets[each.key]
}
