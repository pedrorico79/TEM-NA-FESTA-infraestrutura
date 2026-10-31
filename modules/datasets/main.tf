# Coleta das tendências dos produtos cadastrados no sistema (10, seção 4): a
# Lambda tnf-<env>-tendencias, que faz login na API do backend pelo ALB, lê os
# produtos ativos, consulta o Google Trends e grava no bronze. Nasce e morre
# com o ambiente; roda por infra dataset run <env> (agenda opcional).
# O email e a senha do usuário de coleta ficam só no SSM; a função os lê na
# hora de rodar, pela LabRole (10, seção 8; D10).

data "aws_iam_role" "lab" {
  name = "LabRole"
}

locals {
  function_name = "tnf-${var.env}-tendencias"
  ssm_prefix    = "/tnf/${var.env}/datasets"
}

resource "aws_ssm_parameter" "secret" {
  for_each = toset(["dataset_api_email", "dataset_api_password"])

  name        = "${local.ssm_prefix}/${each.key}"
  description = "Segredo manual ${each.key} da coleta do ambiente ${var.env}"
  type        = "SecureString"
  value       = var.secrets[each.key]
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/aws/lambda/${local.function_name}"
  retention_in_days = 14
}

resource "aws_lambda_function" "this" {
  function_name = local.function_name
  description   = "Tendências dos produtos do sistema no Google Trends (dataset ${var.dataset_ref})"
  role          = data.aws_iam_role.lab.arn
  runtime       = "python3.12"
  handler       = "tnf_tendencias.handler"
  memory_size   = 1024
  timeout       = 900
  layers        = ["arn:aws:lambda:${var.region}:336392948345:layer:AWSSDKPandas-Python312:${var.pandas_layer_version}"]

  filename         = var.lambda_zip_path
  source_code_hash = fileexists(var.lambda_zip_path) ? filebase64sha256(var.lambda_zip_path) : null

  reserved_concurrent_executions = var.reserved_concurrency

  environment {
    variables = {
      TNF_BRONZE_BUCKET = var.bronze_bucket
      TNF_API_URL       = var.api_url
      TNF_ENV           = var.env
      TNF_SSM_PREFIX    = local.ssm_prefix
    }
  }

  depends_on = [aws_cloudwatch_log_group.this, aws_ssm_parameter.secret]
}

resource "aws_lambda_function_event_invoke_config" "this" {
  function_name          = aws_lambda_function.this.function_name
  maximum_retry_attempts = 0
}

resource "aws_cloudwatch_event_rule" "this" {
  count = var.schedule == null ? 0 : 1

  name                = "${local.function_name}-agenda"
  description         = "Coleta agendada dos produtos do sistema (10, seção 4)"
  schedule_expression = var.schedule
}

resource "aws_cloudwatch_event_target" "this" {
  count = var.schedule == null ? 0 : 1

  rule = aws_cloudwatch_event_rule.this[0].name
  arn  = aws_lambda_function.this.arn
}

resource "aws_lambda_permission" "this" {
  count = var.schedule == null ? 0 : 1

  statement_id  = "AllowEventBridgeAgenda"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.this.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.this[0].arn
}
