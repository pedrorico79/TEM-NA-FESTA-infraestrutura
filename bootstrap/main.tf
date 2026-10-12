# Camada 1: configuração dos buckets persistentes, criados uma vez por conta e
# nunca destruídos pelos ambientes (02, seção 2; 05, B3). Os buckets em si são
# criados pelo infra bootstrap com o AWS CLI, fora do Terraform: a SCP do
# laboratório nega s3:GetBucketObjectLockConfiguration, que o recurso
# aws_s3_bucket sempre lê (08, H20). Aqui fica só a configuração, com
# prevent_destroy escrito em cada recurso (08, seção 3). Os objetos nunca são
# alterados nem apagados.

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id

  state_bucket_name  = "tnf-tfstate-${local.account_id}-${var.region}"
  bronze_bucket_name = coalesce(var.bronze_bucket_name, "bucket-bronze-${local.account_id}-${var.bronze_bucket_region}")

  tags = {
    Project   = "tem-na-festa"
    Env       = "shared"
    ManagedBy = "terraform"
  }
}

# --- Bucket do state --------------------------------------------------------------

resource "aws_s3_bucket_versioning" "state" {
  bucket = local.state_bucket_name

  versioning_configuration {
    status = "Enabled"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = local.state_bucket_name

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = local.state_bucket_name

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = local.state_bucket_name
  policy = data.aws_iam_policy_document.tls_only["state"].json

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [aws_s3_bucket_public_access_block.state]
}

# --- Bucket bronze ------------------------------------------------------------------

resource "aws_s3_bucket_server_side_encryption_configuration" "bronze" {
  provider = aws.bronze

  bucket = local.bronze_bucket_name

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_public_access_block" "bronze" {
  provider = aws.bronze

  bucket = local.bronze_bucket_name

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_policy" "bronze" {
  provider = aws.bronze

  bucket = local.bronze_bucket_name
  policy = data.aws_iam_policy_document.tls_only["bronze"].json

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [aws_s3_bucket_public_access_block.bronze]
}

# --- Só TLS (05, B3) -----------------------------------------------------------------

data "aws_iam_policy_document" "tls_only" {
  for_each = {
    state  = "arn:aws:s3:::${local.state_bucket_name}"
    bronze = "arn:aws:s3:::${local.bronze_bucket_name}"
  }

  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    resources = [each.value, "${each.value}/*"]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}
