# Bucket de artefatos do ambiente (02, seção 2; 04, seção 4). O bucket em si
# é criado pelo infra up com o AWS CLI e apagado pelo infra down (a SCP do
# laboratório impede o aws_s3_bucket; 08, H23). Aqui ficam a configuração
# (criptografia, bloqueio de acesso público e só TLS) e os objetos: scripts de
# node/, compose files de stacks/, stack.env, manifesto com o hash e, por
# último, o marcador READY. Os objetos criados em tempo de execução pelos nós
# (swarm/join.json e status/) somem com o bucket no infra down.

locals {
  stack_env_content = join("", [for k in sort(keys(var.stack_env)) : "${k}=${var.stack_env[k]}\n"])

  node_files = {
    "node/node-bootstrap.sh"            = "${var.node_dir}/node-bootstrap.sh"
    "node/converge.sh"                  = "${var.node_dir}/converge.sh"
    "node/tnf-db-shell.sh"              = "${var.node_dir}/tnf-db-shell.sh"
    "node/systemd/tnf-converge.service" = "${var.node_dir}/systemd/tnf-converge.service"
    "node/systemd/tnf-converge.timer"   = "${var.node_dir}/systemd/tnf-converge.timer"
    "node/fluent-bit/parsers.conf"      = "${var.node_dir}/fluent-bit/parsers.conf"
  }

  # Compose files e configurações das stacks (06): tudo em stacks/, menos README.
  stack_files = {
    for f in fileset(var.stacks_dir, "**") :
    "stacks/${f}" => "${var.stacks_dir}/${f}"
    if !endswith(f, "README.md")
  }

  # Hash do conjunto que dispara um novo deploy no líder (04, seção 7).
  manifest_hash = sha256(join("\n", concat(
    [sha256(local.stack_env_content)],
    [for k in sort(keys(local.stack_files)) : "${k}:${filesha256(local.stack_files[k])}"],
  )))
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = var.bucket_name

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket = var.bucket_name

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "tls_only" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    resources = ["arn:aws:s3:::${var.bucket_name}", "arn:aws:s3:::${var.bucket_name}/*"]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "this" {
  bucket = var.bucket_name
  policy = data.aws_iam_policy_document.tls_only.json

  depends_on = [aws_s3_bucket_public_access_block.this]
}

# --- Objetos -------------------------------------------------------------------------

resource "aws_s3_object" "node" {
  for_each = local.node_files

  bucket       = var.bucket_name
  key          = each.key
  source       = each.value
  source_hash  = filesha256(each.value)
  content_type = "text/plain"

  depends_on = [aws_s3_bucket_server_side_encryption_configuration.this]
}

resource "aws_s3_object" "stacks" {
  for_each = local.stack_files

  bucket       = var.bucket_name
  key          = each.key
  source       = each.value
  source_hash  = filesha256(each.value)
  content_type = "text/plain"

  depends_on = [aws_s3_bucket_server_side_encryption_configuration.this]
}

resource "aws_s3_object" "stack_env" {
  bucket       = var.bucket_name
  key          = "stack.env"
  content      = local.stack_env_content
  content_type = "text/plain"

  depends_on = [aws_s3_bucket_server_side_encryption_configuration.this]
}

resource "aws_s3_object" "manifest" {
  bucket       = var.bucket_name
  key          = "manifest.json"
  content      = jsonencode({ hash = local.manifest_hash })
  content_type = "application/json"

  depends_on = [aws_s3_bucket_server_side_encryption_configuration.this]
}

# Marcador gravado por último (04, D5): o líder só converge depois dele.
resource "aws_s3_object" "ready" {
  bucket       = var.bucket_name
  key          = "READY"
  content      = local.manifest_hash
  content_type = "text/plain"

  depends_on = [
    aws_s3_object.node,
    aws_s3_object.stacks,
    aws_s3_object.stack_env,
    aws_s3_object.manifest,
    terraform_data.ready_after,
  ]
}

# Dependências externas do READY (por exemplo, o RDS a partir da E4b).
resource "terraform_data" "ready_after" {
  input = var.ready_after
}
