# =============================================================================
# Projeto Tem Na Festa (Grupo 03) - Infraestrutura AWS em Terraform
# Convertido a partir do template CloudFormation original.
#
# Seções deste arquivo:
#   0. Provider / Data Sources
#   1. VPC e Gateways
#   2. Subnets
#   3. Route Tables
#   4. Security Groups
#   5. Instâncias EC2
#   6. EFS
#   7. RDS MySQL
#   8. Load Balancers e Target Groups
#   9. S3 - Data Lake (bronze/silver/gold)
# =============================================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}
# =========================================================================
# 0. DATA SOURCES
# =========================================================================
data "aws_availability_zones" "available" {
  state = "available"
}

# Equivalente ao Parameter LatestUbuntuAmiId (AWS::SSM::Parameter::Value<AWS::EC2::Image::Id>)
data "aws_ssm_parameter" "ubuntu_ami" {
  name = "/aws/service/canonical/ubuntu/server/22.04/stable/current/amd64/hvm/ebs-gp2/ami-id"
}

data "aws_caller_identity" "current" {}
# =========================================================================
# 1. VPC E GATEWAYS
# =========================================================================
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.project_name}-vpc"
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.project_name}-igw"
  }
}

resource "aws_eip" "nat_a" {
  domain = "vpc"
}

resource "aws_eip" "nat_b" {
  domain = "vpc"
}

resource "aws_nat_gateway" "a" {
  allocation_id = aws_eip.nat_a.id
  subnet_id     = aws_subnet.public_bastion.id

  tags = {
    Name = "${var.project_name}-nat-1a"
  }

  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "b" {
  allocation_id = aws_eip.nat_b.id
  subnet_id     = aws_subnet.public_alb.id

  tags = {
    Name = "${var.project_name}-nat-1b"
  }

  depends_on = [aws_internet_gateway.this]
}
# =========================================================================
# 2. SUBNETS
# =========================================================================
resource "aws_subnet" "public_bastion" {
  vpc_id                  = aws_vpc.this.id
  cidr_block               = "10.0.0.0/27"
  availability_zone        = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch  = true

  tags = {
    Name = "${var.project_name}-public-bastion-1a"
  }
}

resource "aws_subnet" "public_alb" {
  vpc_id                  = aws_vpc.this.id
  cidr_block               = "10.0.0.32/27"
  availability_zone        = data.aws_availability_zones.available.names[1]
  map_public_ip_on_launch  = true

  tags = {
    Name = "${var.project_name}-public-alb-1b"
  }
}

resource "aws_subnet" "private_frontend_1a" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = "10.0.0.64/28"
  availability_zone = data.aws_availability_zones.available.names[0]

  tags = {
    Name = "${var.project_name}-private-frontend-1a"
  }
}

resource "aws_subnet" "private_frontend_1b" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = "10.0.0.80/28"
  availability_zone = data.aws_availability_zones.available.names[1]

  tags = {
    Name = "${var.project_name}-private-frontend-1b"
  }
}

resource "aws_subnet" "private_backend_1a" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = "10.0.0.96/28"
  availability_zone = data.aws_availability_zones.available.names[0]

  tags = {
    Name = "${var.project_name}-private-backend-1a"
  }
}

resource "aws_subnet" "private_backend_1b" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = "10.0.0.112/28"
  availability_zone = data.aws_availability_zones.available.names[1]

  tags = {
    Name = "${var.project_name}-private-backend-1b"
  }
}

resource "aws_subnet" "private_db_1a" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = "10.0.0.128/28"
  availability_zone = data.aws_availability_zones.available.names[0]

  tags = {
    Name = "${var.project_name}-private-db-1a"
  }
}

resource "aws_subnet" "private_db_1b" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = "10.0.0.144/28"
  availability_zone = data.aws_availability_zones.available.names[1]

  tags = {
    Name = "${var.project_name}-private-db-1b"
  }
}
# =========================================================================
# 3. ROUTE TABLES
# =========================================================================
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.project_name}-public-rt"
  }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id              = aws_internet_gateway.this.id
}

# --- Route table privada da AZ A (1a) -> aponta para NatGatewayA ---
resource "aws_route_table" "private_a" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.project_name}-private-rt-1a"
  }
}

resource "aws_route" "private_a_nat" {
  route_table_id         = aws_route_table.private_a.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id          = aws_nat_gateway.a.id
}

# --- Route table privada da AZ B (1b) -> aponta para NatGatewayB ---
resource "aws_route_table" "private_b" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.project_name}-private-rt-1b"
  }
}

resource "aws_route" "private_b_nat" {
  route_table_id         = aws_route_table.private_b.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id          = aws_nat_gateway.b.id
}

# ASSOCIATIONS
resource "aws_route_table_association" "public_bastion" {
  subnet_id      = aws_subnet.public_bastion.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_alb" {
  subnet_id      = aws_subnet.public_alb.id
  route_table_id = aws_route_table.public.id
}

# Subnets da AZ A -> route table da AZ A
resource "aws_route_table_association" "private_frontend_1a" {
  subnet_id      = aws_subnet.private_frontend_1a.id
  route_table_id = aws_route_table.private_a.id
}

resource "aws_route_table_association" "private_backend_1a" {
  subnet_id      = aws_subnet.private_backend_1a.id
  route_table_id = aws_route_table.private_a.id
}

resource "aws_route_table_association" "private_db_1a" {
  subnet_id      = aws_subnet.private_db_1a.id
  route_table_id = aws_route_table.private_a.id
}

# Subnets da AZ B -> route table da AZ B
resource "aws_route_table_association" "private_frontend_1b" {
  subnet_id      = aws_subnet.private_frontend_1b.id
  route_table_id = aws_route_table.private_b.id
}

resource "aws_route_table_association" "private_backend_1b" {
  subnet_id      = aws_subnet.private_backend_1b.id
  route_table_id = aws_route_table.private_b.id
}

resource "aws_route_table_association" "private_db_1b" {
  subnet_id      = aws_subnet.private_db_1b.id
  route_table_id = aws_route_table.private_b.id
}
# =========================================================================
# 4. SECURITY GROUPS
# =========================================================================
resource "aws_security_group" "bastion" {
  name        = "${var.project_name}-sg-bastion"
  description = "Bastion SSH"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.bastion_ssh_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-sg-bastion"
  }
}

resource "aws_security_group" "alb" {
  name        = "${var.project_name}-sg-alb"
  description = "ALB HTTP/HTTPS"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-sg-alb"
  }
}

resource "aws_security_group" "frontend" {
  name        = "${var.project_name}-sg-frontend"
  description = "Frontend"
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "HTTP via ALB"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  ingress {
    description     = "SSH via Bastion"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-sg-frontend"
  }
}

resource "aws_security_group" "efs" {
  name        = "${var.project_name}-sg-efs"
  description = "EFS NFS"
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "NFS a partir do Frontend"
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [aws_security_group.frontend.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-sg-efs"
  }
}

resource "aws_security_group" "internal_alb" {
  name        = "${var.project_name}-sg-internal-alb"
  description = "ALB Interno - Recebe trafego web apenas do SG do Frontend"
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "HTTP a partir do Frontend"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.frontend.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-sg-internal-alb"
  }
}

resource "aws_security_group" "backend" {
  name        = "${var.project_name}-sg-backend"
  description = "Backend Spring Boot"
  vpc_id      = aws_vpc.this.id

  # O backend só aceita requisições via Load Balancer Interno!
  ingress {
    description     = "App port via ALB interno"
    from_port       = var.backend_port
    to_port         = var.backend_port
    protocol        = "tcp"
    security_groups = [aws_security_group.internal_alb.id]
  }

  # Mantém o SSH via Bastion
  ingress {
    description     = "SSH via Bastion"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-sg-backend"
  }
}

resource "aws_security_group" "rds" {
  name        = "${var.project_name}-sg-rds"
  description = "RDS MySQL"
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "MySQL a partir do Backend"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.backend.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-sg-rds"
  }
}
# =========================================================================
# 5. INSTANCIAS EC2
# =========================================================================
resource "aws_instance" "bastion" {
  ami                    = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type          = var.instance_type_bastion
  subnet_id              = aws_subnet.public_bastion.id
  vpc_security_group_ids = [aws_security_group.bastion.id]
  key_name               = var.key_pair_name

  tags = {
    Name = "${var.project_name}-bastion"
  }
}

locals {
  frontend_user_data = <<-EOF
    #!/bin/bash
    apt-get update -y
    apt-get install -y nginx nfs-common
    # Montar o EFS (o DNS do EFS é gerado dinamicamente)
    mkdir -p /var/www/html
    mount -t nfs4 -o nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,noresvport ${aws_efs_file_system.this.id}.efs.${var.aws_region}.amazonaws.com:/ /var/www/html
    systemctl start nginx
    systemctl enable nginx
    echo "<html><body><h1>%s</h1></body></html>" > /var/www/html/index.html
  EOF
}

resource "aws_instance" "frontend_1" {
  ami                    = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type          = var.instance_type_frontend
  subnet_id              = aws_subnet.private_frontend_1a.id
  vpc_security_group_ids = [aws_security_group.frontend.id]
  key_name               = var.key_pair_name
  user_data_base64       = base64encode(format(local.frontend_user_data, "Frontend 1 - AZ A (Nginx)"))

  tags = {
    Name = "${var.project_name}-frontend-1a"
  }
}

resource "aws_instance" "frontend_2" {
  ami                    = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type          = var.instance_type_frontend
  subnet_id              = aws_subnet.private_frontend_1b.id
  vpc_security_group_ids = [aws_security_group.frontend.id]
  key_name               = var.key_pair_name
  user_data_base64       = base64encode(format(local.frontend_user_data, "Frontend 2 - AZ B (Nginx)"))

  tags = {
    Name = "${var.project_name}-frontend-1b"
  }
}

resource "aws_instance" "backend_1" {
  ami                    = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type          = var.instance_type_backend
  subnet_id              = aws_subnet.private_backend_1a.id
  vpc_security_group_ids = [aws_security_group.backend.id]
  key_name               = var.key_pair_name

  tags = {
    Name = "${var.project_name}-backend-1a"
  }
}

resource "aws_instance" "backend_2" {
  ami                    = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type          = var.instance_type_backend
  subnet_id              = aws_subnet.private_backend_1b.id
  vpc_security_group_ids = [aws_security_group.backend.id]
  key_name               = var.key_pair_name

  tags = {
    Name = "${var.project_name}-backend-1b"
  }
}
# =========================================================================
# 6. EFS
# =========================================================================
resource "aws_efs_file_system" "this" {
  performance_mode = "generalPurpose"
  encrypted        = true

  tags = {
    Name = "${var.project_name}-efs"
  }
}

resource "aws_efs_mount_target" "az_a" {
  file_system_id  = aws_efs_file_system.this.id
  subnet_id       = aws_subnet.private_frontend_1a.id
  security_groups = [aws_security_group.efs.id]
}

resource "aws_efs_mount_target" "az_b" {
  file_system_id  = aws_efs_file_system.this.id
  subnet_id       = aws_subnet.private_frontend_1b.id
  security_groups = [aws_security_group.efs.id]
}
# =========================================================================
# 7. RDS MYSQL
# =========================================================================
resource "aws_db_subnet_group" "this" {
  name        = "${var.project_name}-rds-subnet-group"
  description = "Subnet group para RDS ${var.project_name}"
  subnet_ids = [
    aws_subnet.private_db_1a.id,
    aws_subnet.private_db_1b.id,
  ]

  tags = {
    Name = "${var.project_name}-rds-subnet-group"
  }
}

resource "aws_db_instance" "this" {
  identifier     = "${var.project_name}-mysql"
  instance_class = var.db_instance_class
  engine         = "mysql"
  engine_version = "8.0.46"

  username = var.db_master_username
  password = var.db_master_password
  db_name  = var.db_name

  allocated_storage = 20
  storage_type       = "gp3"
  storage_encrypted  = true

  vpc_security_group_ids = [aws_security_group.rds.id]
  db_subnet_group_name    = aws_db_subnet_group.this.name

  # MultiAZ habilitado: RDS provisiona automaticamente uma instância
  # standby síncrona na outra AZ do DB subnet group e faz failover
  # automático em caso de falha da AZ primária.
  # Custo: aprox. dobra o custo do RDS (instância + storage replicados).
  multi_az = true

  publicly_accessible       = false
  backup_retention_period   = 7
  deletion_protection       = false # Setar false temporariamente para facilitar deleção do lab
  skip_final_snapshot       = true

  tags = {
    Name = "${var.project_name}-mysql"
  }
}
# =========================================================================
# 8. LOAD BALANCER E TARGET GROUP
# =========================================================================
resource "aws_lb_target_group" "frontend" {
  name        = "${var.project_name}-frontend-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.this.id
  target_type = "instance"

  health_check {
    path                = "/"
    protocol            = "HTTP"
    interval            = 30
  }

  tags = {
    Name = "${var.project_name}-frontend-tg"
  }
}

resource "aws_lb_target_group_attachment" "frontend_1" {
  target_group_arn = aws_lb_target_group.frontend.arn
  target_id        = aws_instance.frontend_1.id
  port             = 80
}

resource "aws_lb_target_group_attachment" "frontend_2" {
  target_group_arn = aws_lb_target_group.frontend.arn
  target_id        = aws_instance.frontend_2.id
  port             = 80
}

resource "aws_lb" "public" {
  name               = "${var.project_name}-alb"
  internal           = false
  load_balancer_type = "application"
  subnets = [
    aws_subnet.public_bastion.id,
    aws_subnet.public_alb.id,
  ]
  security_groups = [aws_security_group.alb.id]

  tags = {
    Name = "${var.project_name}-alb"
  }
}

resource "aws_lb_listener" "public_http" {
  load_balancer_arn = aws_lb.public.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.frontend.arn
  }
}

resource "aws_lb_target_group" "backend" {
  name        = "${var.project_name}-backend-tg"
  port        = var.backend_port
  protocol    = "HTTP"
  vpc_id      = aws_vpc.this.id
  target_type = "instance"

  health_check {
    path                = "/"
    protocol            = "HTTP"
    interval            = 30
  }

  tags = {
    Name = "${var.project_name}-backend-tg"
  }
}

resource "aws_lb_target_group_attachment" "backend_1" {
  target_group_arn = aws_lb_target_group.backend.arn
  target_id        = aws_instance.backend_1.id
  port             = var.backend_port
}

resource "aws_lb_target_group_attachment" "backend_2" {
  target_group_arn = aws_lb_target_group.backend.arn
  target_id        = aws_instance.backend_2.id
  port             = var.backend_port
}

resource "aws_lb" "internal" {
  name               = "${var.project_name}-internal-alb"
  internal           = true # Fundamental: não expõe o ALB para a internet
  load_balancer_type = "application"
  subnets = [
    aws_subnet.private_backend_1a.id,
    aws_subnet.private_backend_1b.id,
  ]
  security_groups = [aws_security_group.internal_alb.id]

  tags = {
    Name = "${var.project_name}-internal-alb"
  }
}

resource "aws_lb_listener" "internal_http" {
  load_balancer_arn = aws_lb.internal.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.backend.arn
  }
}
# =========================================================================
# 9. AMBIENTE CLOUD PARA ANALISE DE DADOS (S3) - Componente de Nuvem
# -------------------------------------------------------------------------
# Camada de armazenamento separada da aplicação transacional (RDS), para
# suportar análise de dados.
# Segue o padrão de data lake em 3 camadas:
#   - BRONZE: dados brutos exportados do RDS (ou de outras origens),
#     sem transformação, imutáveis.
#   - SILVER: dados limpos/tratados/transformados a partir do BRONZE.
#   - GOLD:   dados curados, prontos para consumo (Dashboard Grafana).
# =========================================================================
resource "aws_s3_bucket" "datalake_bronze" {
  bucket = "${var.project_name}-datalake-bronze-${data.aws_caller_identity.current.account_id}-${var.aws_region}"

  tags = {
    Name   = "${var.project_name}-datalake-bronze"
    Camada = "bronze"
  }
}

resource "aws_s3_bucket_versioning" "datalake_bronze" {
  bucket = aws_s3_bucket.datalake_bronze.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "datalake_bronze" {
  bucket = aws_s3_bucket.datalake_bronze.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "datalake_bronze" {
  bucket                  = aws_s3_bucket.datalake_bronze.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "datalake_bronze" {
  bucket = aws_s3_bucket.datalake_bronze.id

  rule {
    id     = "TransicaoParaInfrequentAccess"
    status = "Enabled"

    filter {} # regra se aplica a todos os objetos do bucket

    transition {
      days          = 90
      storage_class = "STANDARD_IA"
    }
  }
}

resource "aws_s3_bucket" "datalake_silver" {
  bucket = "${var.project_name}-datalake-silver-${data.aws_caller_identity.current.account_id}-${var.aws_region}"

  tags = {
    Name   = "${var.project_name}-datalake-silver"
    Camada = "silver"
  }
}

resource "aws_s3_bucket_versioning" "datalake_silver" {
  bucket = aws_s3_bucket.datalake_silver.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "datalake_silver" {
  bucket = aws_s3_bucket.datalake_silver.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "datalake_silver" {
  bucket                  = aws_s3_bucket.datalake_silver.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket" "datalake_gold" {
  bucket = "${var.project_name}-datalake-gold-${data.aws_caller_identity.current.account_id}-${var.aws_region}"

  tags = {
    Name   = "${var.project_name}-datalake-gold"
    Camada = "gold"
  }
}

resource "aws_s3_bucket_versioning" "datalake_gold" {
  bucket = aws_s3_bucket.datalake_gold.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "datalake_gold" {
  bucket = aws_s3_bucket.datalake_gold.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "datalake_gold" {
  bucket                  = aws_s3_bucket.datalake_gold.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
