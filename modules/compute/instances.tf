# IAM: manager só escreve o token, workers só leem

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

locals {
  swarm_token_param_name = "/${var.project_name}/swarm/worker-token"
  swarm_token_param_arn  = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${local.swarm_token_param_name}"
}

# Para Learner Lab, usamos a role fornecida pelo lab em vez de criar novas.
resource "aws_iam_instance_profile" "swarm_manager" {
  name = "${var.project_name}-swarm-manager"
  role = var.iam_instance_profile_name
}

resource "aws_iam_instance_profile" "swarm_worker" {
  name = "${var.project_name}-swarm-worker"
  role = var.iam_instance_profile_name
}

# ---------------------------------------------------------------------------
# Bastion
# ---------------------------------------------------------------------------

resource "aws_instance" "bastion" {
  ami                    = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type          = var.instance_type_bastion
  subnet_id              = var.public_bastion_subnet_id
  vpc_security_group_ids = [aws_security_group.bastion.id]
  key_name               = var.key_pair_name

  tags = {
    Name = "${var.project_name}-bastion"
  }
}

# ---------------------------------------------------------------------------
# User-data
# ---------------------------------------------------------------------------

locals {
  # Manager: Docker + EFS + Swarm init + publica o worker token no SSM.
  frontend_manager_user_data = <<-EOF
    #!/bin/bash
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive

    mkdir -p /etc/docker
    echo '{"labels":["camada=frontend"]}' > /etc/docker/daemon.json

    apt-get update -y
    apt-get install -y docker.io nfs-common
    systemctl start docker
    systemctl enable docker
    usermod -aG docker ubuntu

    snap wait system seed.loaded
    snap install aws-cli --classic

    WEB_ROOT="/var/www/html"
    EFS_DNS="${var.efs_id}.efs.${var.aws_region}.amazonaws.com"

    install -d -m 0755 "$WEB_ROOT"
    echo "$EFS_DNS:/ $WEB_ROOT nfs4 defaults,_netdev,nofail,nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,noresvport 0 0" >> /etc/fstab
    mount -a

    docker swarm init --advertise-addr "$(hostname -I | awk '{print $1}')"

    PUBLISHED=0
    for i in $(seq 1 30); do
      if /snap/bin/aws ssm put-parameter \
          --region ${var.aws_region} \
          --name "${local.swarm_token_param_name}" \
          --type SecureString --overwrite \
          --value "$(docker swarm join-token -q worker)"; then
        PUBLISHED=1
        break
      fi
      sleep 10
    done

    if [ "$PUBLISHED" -ne 1 ]; then
      echo "ERRO: não foi possível publicar o worker token no SSM" >&2
      exit 1
    fi
  EOF

  # Worker Frontend: Docker + EFS + join automático no Swarm.
  frontend_worker_user_data = <<-EOF
    #!/bin/bash
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive

    mkdir -p /etc/docker
    echo '{"labels":["camada=frontend"]}' > /etc/docker/daemon.json

    apt-get update -y
    apt-get install -y docker.io nfs-common
    systemctl start docker
    systemctl enable docker
    usermod -aG docker ubuntu

    snap wait system seed.loaded
    snap install aws-cli --classic

    WEB_ROOT="/var/www/html"
    EFS_DNS="${var.efs_id}.efs.${var.aws_region}.amazonaws.com"

    install -d -m 0755 "$WEB_ROOT"
    echo "$EFS_DNS:/ $WEB_ROOT nfs4 defaults,_netdev,nofail,nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,noresvport 0 0" >> /etc/fstab
    mount -a

    for i in $(seq 1 60); do
      TOKEN=$(/snap/bin/aws ssm get-parameter \
        --region ${var.aws_region} \
        --name "${local.swarm_token_param_name}" \
        --with-decryption --query Parameter.Value --output text 2>/dev/null || true)

      if [ -n "$TOKEN" ] && docker swarm join --token "$TOKEN" ${aws_instance.frontend_1.private_ip}:2377; then
        break
      fi
      sleep 10
    done

    if [ "$(docker info --format '{{.Swarm.LocalNodeState}}')" != "active" ]; then
      echo "ERRO: este nó não entrou no Swarm" >&2
      exit 1
    fi
  EOF

  # Worker Backend: Docker + cliente MySQL + join automático no Swarm.
  backend_worker_user_data = <<-EOF
    #!/bin/bash
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive

    mkdir -p /etc/docker
    echo '{"labels":["camada=backend"]}' > /etc/docker/daemon.json

    apt-get update -y
    apt-get install -y docker.io default-mysql-client
    systemctl start docker
    systemctl enable docker
    usermod -aG docker ubuntu

    snap wait system seed.loaded
    snap install aws-cli --classic

    for i in $(seq 1 60); do
      TOKEN=$(/snap/bin/aws ssm get-parameter \
        --region ${var.aws_region} \
        --name "${local.swarm_token_param_name}" \
        --with-decryption --query Parameter.Value --output text 2>/dev/null || true)

      if [ -n "$TOKEN" ] && docker swarm join --token "$TOKEN" ${aws_instance.frontend_1.private_ip}:2377; then
        break
      fi
      sleep 10
    done

    if [ "$(docker info --format '{{.Swarm.LocalNodeState}}')" != "active" ]; then
      echo "ERRO: este nó não entrou no Swarm" >&2
      exit 1
    fi
  EOF
}

# ---------------------------------------------------------------------------
# Instâncias do Swarm
# ---------------------------------------------------------------------------

resource "aws_instance" "frontend_1" {
  ami                         = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type               = var.instance_type_frontend
  subnet_id                   = var.private_frontend_subnet_ids[0]
  vpc_security_group_ids      = [aws_security_group.frontend.id, aws_security_group.swarm_comunicacao.id, aws_security_group.bastion.id]
  key_name                    = var.key_pair_name
  iam_instance_profile        = aws_iam_instance_profile.swarm_manager.name
  user_data_base64            = base64encode(local.frontend_manager_user_data)
  user_data_replace_on_change = true

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  tags = {
    Name = "${var.project_name}-frontend-1a (Manager)"
  }
}

resource "aws_instance" "frontend_2" {
  ami                         = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type               = var.instance_type_frontend
  subnet_id                   = var.private_frontend_subnet_ids[1]
  vpc_security_group_ids      = [aws_security_group.frontend.id, aws_security_group.swarm_comunicacao.id, aws_security_group.bastion.id]
  key_name                    = var.key_pair_name
  iam_instance_profile        = aws_iam_instance_profile.swarm_worker.name
  user_data_base64            = base64encode(local.frontend_worker_user_data)
  user_data_replace_on_change = true

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  tags = {
    Name = "${var.project_name}-frontend-1b (Worker)"
  }
}

resource "aws_instance" "backend_1" {
  ami                         = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type               = var.instance_type_backend
  subnet_id                   = var.private_backend_subnet_ids[0]
  vpc_security_group_ids      = [aws_security_group.backend.id, aws_security_group.swarm_comunicacao.id, aws_security_group.bastion.id]
  key_name                    = var.key_pair_name
  iam_instance_profile        = aws_iam_instance_profile.swarm_worker.name
  user_data_base64            = base64encode(local.backend_worker_user_data)
  user_data_replace_on_change = true

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  tags = {
    Name = "${var.project_name}-backend-1a (Worker)"
  }
}

resource "aws_instance" "backend_2" {
  ami                         = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type               = var.instance_type_backend
  subnet_id                   = var.private_backend_subnet_ids[1]
  vpc_security_group_ids      = [aws_security_group.backend.id, aws_security_group.swarm_comunicacao.id, aws_security_group.bastion.id]
  key_name                    = var.key_pair_name
  iam_instance_profile        = aws_iam_instance_profile.swarm_worker.name
  user_data_base64            = base64encode(local.backend_worker_user_data)
  user_data_replace_on_change = true

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
}

  tags = {
    Name = "${var.project_name}-backend-1b (Worker)"
  }
}

# ---------------------------------------------------------------------------
# Limpeza: remove o parâmetro criado pelo manager no "terraform destroy"
# ---------------------------------------------------------------------------

resource "terraform_data" "swarm_token_cleanup" {
  input = {
    name   = local.swarm_token_param_name
    region = var.aws_region
  }

  provisioner "local-exec" {
    when       = destroy
    on_failure = continue
    command    = "aws ssm delete-parameter --region ${self.input.region} --name ${self.input.name}"
  }
}