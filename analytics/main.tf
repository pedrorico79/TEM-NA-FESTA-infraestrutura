# Camada persistente de dados analíticos: catálogo do Glue sobre o bronze,
# workgroup do Athena e bucket de resultados. A coleta dos produtos ativos é
# provisionada junto de cada ambiente em modules/datasets; infra down não toca
# nesta camada compartilhada.
# O bucket de resultados é criado por infra analytics up com o AWS CLI.

data "aws_caller_identity" "current" {}

locals {
  account_id         = data.aws_caller_identity.current.account_id
  bronze_bucket_name = coalesce(var.bronze_bucket_name, "bucket-bronze-${local.account_id}-${var.region}")
  results_bucket     = "tnf-athena-${local.account_id}-${var.region}"
  tags = {
    Project   = "tem-na-festa"
    Env       = "shared"
    ManagedBy = "terraform"
  }
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
