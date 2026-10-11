# Camada 1: buckets persistentes, criados uma vez por conta e nunca
# destruídos pelos ambientes (02, seção 2; 05, B3). Sem módulos: o
# prevent_destroy precisa estar escrito no próprio recurso (08, seção 3).
# Se um bucket já existe (por exemplo, o bronze), o infra bootstrap o
# importa antes do plan; os objetos nunca são alterados nem apagados.

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

resource "aws_s3_bucket" "state" {
  bucket = local.state_bucket_name

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.tls_only["state"].json

  depends_on = [aws_s3_bucket_public_access_block.state]
}

# --- Bucket bronze ------------------------------------------------------------------

resource "aws_s3_bucket" "bronze" {
  provider = aws.bronze

  bucket = local.bronze_bucket_name

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "bronze" {
  provider = aws.bronze

  bucket = aws_s3_bucket.bronze.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "bronze" {
  provider = aws.bronze

  bucket = aws_s3_bucket.bronze.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "bronze" {
  provider = aws.bronze

  bucket = aws_s3_bucket.bronze.id
  policy = data.aws_iam_policy_document.tls_only["bronze"].json

  depends_on = [aws_s3_bucket_public_access_block.bronze]
}

# --- Só TLS (05, B3) -----------------------------------------------------------------

data "aws_iam_policy_document" "tls_only" {
  for_each = {
    state  = aws_s3_bucket.state.arn
    bronze = aws_s3_bucket.bronze.arn
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
