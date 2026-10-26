# Nós do ambiente (02, seção 4; 04, seção 5; 08, seções 3 e 4.1): par de
# chaves gerado pelo Terraform, nós web e app do Swarm com IP fixo (03, seção
# 5) e o bastion. Todas as instâncias usam o LabInstanceProfile, exigem IMDSv2
# com limite de saltos 1 (A14, regra fixa, sem variável) e nunca são
# substituídas por uma AMI mais nova (03, seção 3.3).

locals {
  # Unidades do systemd enviadas ao bronze (02, seção 7.1). Para coletar outra,
  # acrescente aqui e recrie o nó.
  fluent_bit_systemd_units = [
    "docker.service",
    "ssh.service",
    "fluent-bit.service",
    "cloud-init.service",
    "cloud-config.service",
    "cloud-final.service",
    "tnf-converge.service",
  ]

  ami_id = var.ami_id != null ? var.ami_id : data.aws_ami.ubuntu[0].id

  instance_type = {
    web = var.web_instance_type
    app = var.app_instance_type
  }

  leader_ip = var.nodes["app-1"].private_ip

  bastion_hostname = "${var.name_prefix}-bastion"

  # Configuração do Fluent Bit por nó (hostname e papel embutidos).
  fluent_bit_hosts = merge(
    { for k, n in var.nodes : n.hostname => { role = n.group, docker = true } },
    var.bastion_enabled ? { (local.bastion_hostname) = { role = "bastion", docker = false } } : {},
  )
}

data "aws_ami" "ubuntu" {
  count = var.ami_id == null ? 1 : 0

  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

data "aws_iam_instance_profile" "lab" {
  name = "LabInstanceProfile"
}

# --- Chave SSH --------------------------------------------------------------------
# A privada fica no state (saída sensível, recuperável pelo infra access) e
# numa cópia local 600 (05, A6; 08, seção 5.6).

resource "tls_private_key" "ssh" {
  algorithm = "ED25519"
}

resource "aws_key_pair" "this" {
  key_name   = "${var.name_prefix}-key"
  public_key = tls_private_key.ssh.public_key_openssh
}

resource "local_sensitive_file" "ssh_private_key" {
  filename             = var.ssh_private_key_path
  content              = tls_private_key.ssh.private_key_openssh
  file_permission      = "0600"
  directory_permission = "0700"
}

# --- Configuração do Fluent Bit (02, seção 7.1) -----------------------------------

resource "aws_s3_object" "fluent_bit" {
  for_each = local.fluent_bit_hosts

  bucket       = var.artifacts_bucket
  key          = "node/fluent-bit/${each.key}.conf"
  content_type = "text/plain"
  content = templatefile("${var.node_dir}/fluent-bit/fluent-bit.conf.tftpl", {
    env           = var.env
    hostname      = each.key
    role          = each.value.role
    docker        = each.value.docker
    bronze_bucket = var.bronze_bucket
    bronze_region = var.bronze_region
    systemd_units = local.fluent_bit_systemd_units
  })
}

# Scripts de node/ já no bucket antes de as instâncias nascerem (04, seção 4).
resource "terraform_data" "node_objects" {
  input = var.node_objects
}

# --- Nós do Swarm --------------------------------------------------------------------

resource "aws_instance" "node" {
  for_each = var.nodes

  ami                         = local.ami_id
  instance_type               = local.instance_type[each.value.group]
  subnet_id                   = var.subnet_ids[each.value.group][each.value.az_index]
  private_ip                  = each.value.private_ip
  vpc_security_group_ids      = [var.security_group_ids["swarm_${each.value.group}"]]
  key_name                    = aws_key_pair.this.key_name
  iam_instance_profile        = data.aws_iam_instance_profile.lab.name
  associate_public_ip_address = false

  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    env              = var.env
    role             = each.value.group
    hostname         = each.value.hostname
    region           = var.region
    artifacts_bucket = var.artifacts_bucket
    leader_ip        = local.leader_ip
    manager          = each.value.manager
  })

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_size_gb
    encrypted   = true
  }

  tags = {
    Name = each.value.hostname
    Role = each.value.group
  }

  lifecycle {
    ignore_changes = [ami]
  }

  depends_on = [aws_s3_object.fluent_bit, terraform_data.node_objects]
}

# --- Bastion ---------------------------------------------------------------------------

resource "aws_instance" "bastion" {
  count = var.bastion_enabled ? 1 : 0

  ami                         = local.ami_id
  instance_type               = var.bastion_instance_type
  subnet_id                   = var.subnet_ids["public"][0]
  vpc_security_group_ids      = [var.security_group_ids["bastion"]]
  key_name                    = aws_key_pair.this.key_name
  iam_instance_profile        = data.aws_iam_instance_profile.lab.name
  associate_public_ip_address = true

  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    env              = var.env
    role             = "bastion"
    hostname         = local.bastion_hostname
    region           = var.region
    artifacts_bucket = var.artifacts_bucket
    leader_ip        = local.leader_ip
    manager          = false
  })

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_size_gb
    encrypted   = true
  }

  tags = {
    Name = local.bastion_hostname
    Role = "bastion"
  }

  lifecycle {
    ignore_changes = [ami]
  }

  depends_on = [aws_s3_object.fluent_bit, terraform_data.node_objects]
}
