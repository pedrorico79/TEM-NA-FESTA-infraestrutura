# Data lake S3 buckets (optional)

resource "aws_s3_bucket" "datalake_bronze" {
  count = var.enable_datalake ? 1 : 0

  bucket = "${var.project_name}-datalake-bronze-${data.aws_caller_identity.current.account_id}-${var.aws_region}"

  tags = {
    Name   = "${var.project_name}-datalake-bronze"
    Camada = "bronze"
  }
}

resource "aws_s3_bucket_versioning" "datalake_bronze" {
  count = var.enable_datalake ? 1 : 0

  bucket = aws_s3_bucket.datalake_bronze[0].id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "datalake_bronze" {
  count = var.enable_datalake ? 1 : 0

  bucket = aws_s3_bucket.datalake_bronze[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "datalake_bronze" {
  count = var.enable_datalake ? 1 : 0

  bucket                  = aws_s3_bucket.datalake_bronze[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "datalake_bronze" {
  count = var.enable_datalake ? 1 : 0

  bucket = aws_s3_bucket.datalake_bronze[0].id

  rule {
    id     = "TransicaoParaInfrequentAccess"
    status = "Enabled"

    filter {}

    transition {
      days          = 90
      storage_class = "STANDARD_IA"
    }
  }
}

resource "aws_s3_bucket" "datalake_silver" {
  count = var.enable_datalake ? 1 : 0

  bucket = "${var.project_name}-datalake-silver-${data.aws_caller_identity.current.account_id}-${var.aws_region}"

  tags = {
    Name   = "${var.project_name}-datalake-silver"
    Camada = "silver"
  }
}

resource "aws_s3_bucket_versioning" "datalake_silver" {
  count = var.enable_datalake ? 1 : 0

  bucket = aws_s3_bucket.datalake_silver[0].id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "datalake_silver" {
  count = var.enable_datalake ? 1 : 0

  bucket = aws_s3_bucket.datalake_silver[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "datalake_silver" {
  count = var.enable_datalake ? 1 : 0

  bucket                  = aws_s3_bucket.datalake_silver[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket" "datalake_gold" {
  count = var.enable_datalake ? 1 : 0

  bucket = "${var.project_name}-datalake-gold-${data.aws_caller_identity.current.account_id}-${var.aws_region}"

  tags = {
    Name   = "${var.project_name}-datalake-gold"
    Camada = "gold"
  }
}

resource "aws_s3_bucket_versioning" "datalake_gold" {
  count = var.enable_datalake ? 1 : 0

  bucket = aws_s3_bucket.datalake_gold[0].id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "datalake_gold" {
  count = var.enable_datalake ? 1 : 0

  bucket = aws_s3_bucket.datalake_gold[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "datalake_gold" {
  count = var.enable_datalake ? 1 : 0

  bucket                  = aws_s3_bucket.datalake_gold[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
