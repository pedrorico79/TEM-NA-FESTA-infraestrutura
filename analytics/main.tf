# Camada persistente de dados analíticos (10): a Lambda semanal da base da
# "Especificação de Base de Dados" (POF/IBGE + Google Trends), o catálogo do
# Glue sobre o bronze, o workgroup do Athena e a configuração do bucket de
# resultados. Fica no ar com ou sem ambiente; o infra down não a toca.
# O bucket de resultados é criado pelo infra analytics up com o AWS CLI, como
# os outros buckets (08, H20); aqui fica só a configuração dele.

data "aws_caller_identity" "current" {}

# A LabRole é o único papel disponível no laboratório (01, RES-03).
data "aws_iam_role" "lab" {
  name = "LabRole"
}

locals {
  account_id         = data.aws_caller_identity.current.account_id
  bronze_bucket_name = coalesce(var.bronze_bucket_name, "bucket-bronze-${local.account_id}-${var.region}")
  results_bucket     = "tnf-athena-${local.account_id}-${var.region}"
  lambda_zip_path    = coalesce(var.lambda_zip_path, abspath("${path.module}/../.infra/build/pof-trends-${var.dataset_ref}.zip"))
  pandas_layer_arn   = "arn:aws:lambda:${var.region}:336392948345:layer:AWSSDKPandas-Python312:${var.pandas_layer_version}"

  tags = {
    Project   = "tem-na-festa"
    Env       = "shared"
    ManagedBy = "terraform"
  }
}

# --- Lambda da base da EBD (10, seção 4) -----------------------------------------------

resource "aws_cloudwatch_log_group" "pof_trends" {
  name              = "/aws/lambda/tnf-coleta-pof-trends"
  retention_in_days = 14
}

resource "aws_lambda_function" "pof_trends" {
  function_name = "tnf-coleta-pof-trends"
  description   = "Coleta semanal da base POF/IBGE + Google Trends (${var.dataset_repo_url} na tag ${var.dataset_ref})"
  role          = data.aws_iam_role.lab.arn
  runtime       = "python3.12"
  handler       = "tnf_pof_trends.handler"
  memory_size   = 1024
  timeout       = 900
  layers        = [local.pandas_layer_arn]

  filename         = local.lambda_zip_path
  source_code_hash = fileexists(local.lambda_zip_path) ? filebase64sha256(local.lambda_zip_path) : null

  reserved_concurrent_executions = var.lambda_reserved_concurrency

  # Sem segredos: esta coleta não usa nenhum (10, seção 8).
  environment {
    variables = {
      TNF_BRONZE_BUCKET = local.bronze_bucket_name
      TNF_DATASET_REF   = var.dataset_ref
    }
  }

  depends_on = [aws_cloudwatch_log_group.pof_trends]
}

# Sem novas tentativas automáticas: uma falha do Google Trends repetida em
# seguida só pioraria o 429; a próxima tentativa é a da semana seguinte ou o
# infra dataset run.
resource "aws_lambda_function_event_invoke_config" "pof_trends" {
  function_name          = aws_lambda_function.pof_trends.function_name
  maximum_retry_attempts = 0
}

resource "aws_cloudwatch_event_rule" "pof_trends" {
  count = var.pof_trends_schedule == null ? 0 : 1

  name                = "tnf-coleta-pof-trends-semanal"
  description         = "Coleta semanal da base da EBD (10, seção 4)"
  schedule_expression = var.pof_trends_schedule
}

resource "aws_cloudwatch_event_target" "pof_trends" {
  count = var.pof_trends_schedule == null ? 0 : 1

  rule = aws_cloudwatch_event_rule.pof_trends[0].name
  arn  = aws_lambda_function.pof_trends.arn
}

resource "aws_lambda_permission" "pof_trends" {
  count = var.pof_trends_schedule == null ? 0 : 1

  statement_id  = "AllowEventBridgeSemanal"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.pof_trends.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.pof_trends[0].arn
}

# --- Bucket de resultados do Athena (10, seção 6.2) ------------------------------------

resource "aws_s3_bucket_server_side_encryption_configuration" "results" {
  bucket = local.results_bucket

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "results" {
  bucket = local.results_bucket

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "results_tls_only" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    resources = ["arn:aws:s3:::${local.results_bucket}", "arn:aws:s3:::${local.results_bucket}/*"]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "results" {
  bucket = local.results_bucket
  policy = data.aws_iam_policy_document.results_tls_only.json

  depends_on = [aws_s3_bucket_public_access_block.results]
}

resource "aws_s3_bucket_lifecycle_configuration" "results" {
  bucket = local.results_bucket

  rule {
    id     = "expira-resultados"
    status = "Enabled"

    filter {}

    expiration {
      days = 30
    }
  }
}

# --- Athena (10, seção 6.2) -----------------------------------------------------------

resource "aws_athena_workgroup" "tnf" {
  name          = "tnf"
  description   = "Consultas do Tem Na Festa sobre o bronze (10)"
  force_destroy = true

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = false
    bytes_scanned_cutoff_per_query     = var.athena_bytes_scanned_cutoff

    result_configuration {
      output_location = "s3://${local.results_bucket}/resultados/"

      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }
  }
}
