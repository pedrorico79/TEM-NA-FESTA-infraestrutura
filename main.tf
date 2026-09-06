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
  cidr_block              = "10.0.0.0/27"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project_name}-public-bastion-1a"
  }
}

resource "aws_subnet" "public_alb" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = "10.0.0.32/27"
  availability_zone       = data.aws_availability_zones.available.names[1]
  map_public_ip_on_launch = true

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
  gateway_id             = aws_internet_gateway.this.id
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
  nat_gateway_id         = aws_nat_gateway.a.id
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
  nat_gateway_id         = aws_nat_gateway.b.id
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
  backend_db_url = "jdbc:mysql://${aws_db_instance.this.address}:${aws_db_instance.this.port}/${var.db_name}?allowPublicKeyRetrieval=true&useSSL=false&serverTimezone=UTC"

  backend_user_data = <<-EOF
    #!/bin/bash
    set -euo pipefail

    export DEBIAN_FRONTEND=noninteractive

    INITIALIZE_DATABASE="__INITIALIZE_DATABASE__"
    BACKEND_DIR="/opt/tem-na-festa-backend"
    DATABASE_DIR="/opt/tem-na-festa-database"
    SECRETS_DIR="/etc/tem-na-festa"

    log() {
      echo "[backend-user-data] $*"
    }

    retry() {
      local attempt=1
      local max_attempts=5

      until "$@"; do
        if [ "$attempt" -ge "$max_attempts" ]; then
          log "Comando falhou depois de $attempt tentativas: $*"
          return 1
        fi

        log "Tentativa $attempt falhou. Tentando novamente..."
        sleep $((attempt * 10))
        attempt=$((attempt + 1))
      done
    }

    log "Aguardando a rede privada e instalando dependências"
    retry apt-get update -y
    retry apt-get install -y git ca-certificates openjdk-21-jdk-headless default-mysql-client

    if ! id temnafesta >/dev/null 2>&1; then
      useradd --system --home-dir "$BACKEND_DIR" --shell /usr/sbin/nologin temnafesta
    fi

    log "Clonando o backend da branch ${var.backend_repository_branch}"
    retry git clone \
      --depth 1 \
      --single-branch \
      --branch "${var.backend_repository_branch}" \
      "${var.backend_repository_url}" \
      "$BACKEND_DIR"

    log "Compilando o backend"
    cd "$BACKEND_DIR"
    chmod +x mvnw
    export MAVEN_OPTS="-Xmx512m"
    ./mvnw --batch-mode clean package -DskipTests

    BACKEND_JAR="$BACKEND_DIR/target/tem-na-festa-0.0.1-SNAPSHOT.jar"
    if [ ! -f "$BACKEND_JAR" ]; then
      log "JAR não encontrado em $BACKEND_JAR"
      exit 1
    fi

    log "Gravando configuração do serviço"
    install -d -o root -g temnafesta -m 0750 "$SECRETS_DIR"

    cat > "$SECRETS_DIR/db-url.b64" <<'SECRET'
    ${base64encode(local.backend_db_url)}
    SECRET
    cat > "$SECRETS_DIR/db-user.b64" <<'SECRET'
    ${base64encode(var.db_master_username)}
    SECRET
    cat > "$SECRETS_DIR/db-password.b64" <<'SECRET'
    ${base64encode(var.db_master_password)}
    SECRET
    cat > "$SECRETS_DIR/jwt-secret.b64" <<'SECRET'
    ${base64encode(var.jwt_secret)}
    SECRET

    chown root:temnafesta "$SECRETS_DIR"/*.b64
    chmod 0640 "$SECRETS_DIR"/*.b64

    cat > /usr/local/bin/tem-na-festa-backend-start <<'START_SCRIPT'
    #!/bin/bash
    set -euo pipefail

    export DB_URL="$(base64 --decode /etc/tem-na-festa/db-url.b64)"
    export DB_USER="$(base64 --decode /etc/tem-na-festa/db-user.b64)"
    export DB_PASSWORD="$(base64 --decode /etc/tem-na-festa/db-password.b64)"
    export JWT_SECRET="$(base64 --decode /etc/tem-na-festa/jwt-secret.b64)"

    exec /usr/bin/java -jar /opt/tem-na-festa-backend/target/tem-na-festa-0.0.1-SNAPSHOT.jar
    START_SCRIPT
    chmod 0755 /usr/local/bin/tem-na-festa-backend-start

    export MYSQL_PWD="$(base64 --decode "$SECRETS_DIR/db-password.b64")"
    DB_HOST="${aws_db_instance.this.address}"
    DB_PORT="${aws_db_instance.this.port}"
    DB_USER="${var.db_master_username}"
    DB_NAME="${var.db_name}"

    log "Aguardando o RDS aceitar conexões"
    DATABASE_AVAILABLE="false"
    for attempt in $(seq 1 60); do
      if mysql \
        --connect-timeout=5 \
        --protocol=TCP \
        --host="$DB_HOST" \
        --port="$DB_PORT" \
        --user="$DB_USER" \
        "$DB_NAME" \
        --execute="SELECT 1" >/dev/null 2>&1; then
        DATABASE_AVAILABLE="true"
        break
      fi

      log "RDS ainda indisponível (tentativa $attempt/60)"
      sleep 10
    done

    if [ "$DATABASE_AVAILABLE" != "true" ]; then
      log "RDS não ficou disponível dentro do tempo esperado"
      exit 1
    fi

    if [ "$INITIALIZE_DATABASE" = "true" ]; then
      log "Clonando os scripts SQL da branch ${var.database_repository_branch}"
      retry git clone \
        --depth 1 \
        --single-branch \
        --branch "${var.database_repository_branch}" \
        "${var.database_repository_url}" \
        "$DATABASE_DIR"

      SCHEMA_EXISTS="$(mysql \
        --protocol=TCP \
        --host="$DB_HOST" \
        --port="$DB_PORT" \
        --user="$DB_USER" \
        --batch \
        --skip-column-names \
        --execute="SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = '$DB_NAME' AND table_name = 'perfil';")"

      if [ "$SCHEMA_EXISTS" = "0" ]; then
        log "Criando as tabelas no RDS"
        mysql \
          --protocol=TCP \
          --host="$DB_HOST" \
          --port="$DB_PORT" \
          --user="$DB_USER" \
          "$DB_NAME" < "$DATABASE_DIR/script-bd-tem-na-festa.sql"
      else
        log "Estrutura do banco já existe; criação ignorada"
      fi

      SEED_EXISTS="$(mysql \
        --protocol=TCP \
        --host="$DB_HOST" \
        --port="$DB_PORT" \
        --user="$DB_USER" \
        --batch \
        --skip-column-names \
        "$DB_NAME" \
        --execute="SELECT COUNT(*) FROM perfil;")"

      if [ "$SEED_EXISTS" = "0" ]; then
        log "Inserindo os dados iniciais"
        mysql \
          --protocol=TCP \
          --host="$DB_HOST" \
          --port="$DB_PORT" \
          --user="$DB_USER" \
          "$DB_NAME" < "$DATABASE_DIR/script-inserts-tem-na-festa.sql"
      else
        log "Dados iniciais já existem; inserção ignorada"
      fi
    else
      log "Aguardando o backend principal preparar o banco"
      SCHEMA_AVAILABLE="false"
      for attempt in $(seq 1 60); do
        TABLE_COUNT="$(mysql \
          --protocol=TCP \
          --host="$DB_HOST" \
          --port="$DB_PORT" \
          --user="$DB_USER" \
          --batch \
          --skip-column-names \
          --execute="SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = '$DB_NAME' AND table_name = 'perfil';")"

        if [ "$TABLE_COUNT" = "1" ]; then
          SCHEMA_AVAILABLE="true"
          break
        fi

        log "Banco ainda não inicializado (tentativa $attempt/60)"
        sleep 10
      done

      if [ "$SCHEMA_AVAILABLE" != "true" ]; then
        log "O backend principal não preparou o banco dentro do tempo esperado"
        exit 1
      fi
    fi

    unset MYSQL_PWD
    chown -R temnafesta:temnafesta "$BACKEND_DIR"

    cat > /etc/systemd/system/tem-na-festa-backend.service <<'SYSTEMD'
    [Unit]
    Description=Tem Na Festa Backend
    Wants=network-online.target
    After=network-online.target

    [Service]
    Type=simple
    User=temnafesta
    Group=temnafesta
    WorkingDirectory=/opt/tem-na-festa-backend
    Environment=PORT=${var.backend_port}
    ExecStart=/usr/local/bin/tem-na-festa-backend-start
    Restart=always
    RestartSec=10
    SuccessExitStatus=143

    [Install]
    WantedBy=multi-user.target
    SYSTEMD

    systemctl daemon-reload
    systemctl enable --now tem-na-festa-backend.service
    log "Backend configurado e iniciado"
  EOF

  frontend_user_data = <<-EOF
    #!/bin/bash
    set -euo pipefail

    export DEBIAN_FRONTEND=noninteractive

    BUILD_FRONTEND="__BUILD_FRONTEND__"
    FRONTEND_DIR="/opt/tem-na-festa-frontend"
    WEB_ROOT="/var/www/html"
    EFS_DNS="${aws_efs_file_system.this.id}.efs.${var.aws_region}.amazonaws.com"

    log() {
      echo "[frontend-user-data] $*"
    }

    retry() {
      local attempt=1
      local max_attempts=5

      until "$@"; do
        if [ "$attempt" -ge "$max_attempts" ]; then
          log "Comando falhou depois de $attempt tentativas: $*"
          return 1
        fi

        log "Tentativa $attempt falhou. Tentando novamente..."
        sleep $((attempt * 10))
        attempt=$((attempt + 1))
      done
    }

    log "Instalando Nginx e cliente NFS"
    retry apt-get update -y
    retry apt-get install -y nginx nfs-common ca-certificates
    systemctl stop nginx || true

    log "Montando o EFS"
    install -d -m 0755 "$WEB_ROOT"
    if ! grep -Fq "$EFS_DNS:/ $WEB_ROOT " /etc/fstab; then
      echo "$EFS_DNS:/ $WEB_ROOT nfs4 defaults,_netdev,nofail,nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,noresvport 0 0" >> /etc/fstab
    fi

    if ! mountpoint -q "$WEB_ROOT"; then
      retry mount -t nfs4 \
        -o nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,noresvport \
        "$EFS_DNS:/" \
        "$WEB_ROOT"
    fi

    cat > /etc/nginx/sites-available/tem-na-festa <<'NGINX'
    server {
      listen 80 default_server;
      listen [::]:80 default_server;
      server_name _;

      root /var/www/html;
      index index.html;

      location /api/v1/ {
        # Sem barra depois do hostname: preserva /api/v1 na requisição.
        proxy_pass http://${aws_lb.internal.dns_name};
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
      }

      location / {
        try_files $uri $uri/ /index.html;
      }
    }
    NGINX

    rm -f /etc/nginx/sites-enabled/default
    ln -s /etc/nginx/sites-available/tem-na-festa /etc/nginx/sites-enabled/tem-na-festa

    if [ "$BUILD_FRONTEND" = "true" ]; then
      log "Instalando Node.js 22"
      retry apt-get install -y git curl rsync
      retry curl -fsSL https://deb.nodesource.com/setup_22.x -o /tmp/nodesource_setup.sh
      retry bash /tmp/nodesource_setup.sh
      retry apt-get install -y nodejs

      NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
      if [ "$NODE_MAJOR" -lt 22 ]; then
        log "Node.js 22 ou superior era esperado, mas foi encontrado $(node --version)"
        exit 1
      fi

      log "Clonando o frontend da branch ${var.frontend_repository_branch}"
      retry git clone \
        --depth 1 \
        --single-branch \
        --branch "${var.frontend_repository_branch}" \
        "${var.frontend_repository_url}" \
        "$FRONTEND_DIR"

      log "Compilando o frontend"
      cd "$FRONTEND_DIR"
      export NODE_OPTIONS="--max-old-space-size=512"
      npm ci --no-audit --no-fund
      npm run build

      if [ ! -s "$FRONTEND_DIR/dist/index.html" ]; then
        log "O build não gerou dist/index.html"
        exit 1
      fi

      log "Publicando o build no EFS"
      rsync \
        --archive \
        --delete \
        --exclude=index.html \
        "$FRONTEND_DIR/dist/" \
        "$WEB_ROOT/"
      install -m 0644 "$FRONTEND_DIR/dist/index.html" "$WEB_ROOT/index.html"
    else
      log "Aguardando o frontend principal publicar index.html"
      INDEX_AVAILABLE="false"
      for attempt in $(seq 1 90); do
        if [ -s "$WEB_ROOT/index.html" ]; then
          INDEX_AVAILABLE="true"
          break
        fi

        log "index.html ainda não disponível (tentativa $attempt/90)"
        sleep 10
      done

      if [ "$INDEX_AVAILABLE" != "true" ]; then
        log "O frontend principal não publicou index.html dentro do tempo esperado"
        exit 1
      fi
    fi

    chown -R www-data:www-data "$WEB_ROOT"
    nginx -t
    systemctl enable nginx
    systemctl restart nginx
    log "Frontend configurado e iniciado"
  EOF
}

resource "aws_instance" "frontend_1" {
  ami                         = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type               = var.instance_type_frontend
  subnet_id                   = aws_subnet.private_frontend_1a.id
  vpc_security_group_ids      = [aws_security_group.frontend.id]
  key_name                    = var.key_pair_name
  user_data_base64            = base64encode(replace(local.frontend_user_data, "__BUILD_FRONTEND__", "true"))
  user_data_replace_on_change = true

  depends_on = [
    aws_route.private_a_nat,
    aws_route_table_association.private_frontend_1a,
    aws_efs_mount_target.az_a,
    aws_lb_listener.internal_http,
  ]

  tags = {
    Name = "${var.project_name}-frontend-1a"
  }
}

resource "aws_instance" "frontend_2" {
  ami                         = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type               = var.instance_type_frontend
  subnet_id                   = aws_subnet.private_frontend_1b.id
  vpc_security_group_ids      = [aws_security_group.frontend.id]
  key_name                    = var.key_pair_name
  user_data_base64            = base64encode(replace(local.frontend_user_data, "__BUILD_FRONTEND__", "false"))
  user_data_replace_on_change = true

  depends_on = [
    aws_route.private_b_nat,
    aws_route_table_association.private_frontend_1b,
    aws_efs_mount_target.az_b,
    aws_lb_listener.internal_http,
  ]

  tags = {
    Name = "${var.project_name}-frontend-1b"
  }
}

resource "aws_instance" "backend_1" {
  ami                         = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type               = var.instance_type_backend
  subnet_id                   = aws_subnet.private_backend_1a.id
  vpc_security_group_ids      = [aws_security_group.backend.id]
  key_name                    = var.key_pair_name
  user_data_base64            = base64encode(replace(local.backend_user_data, "__INITIALIZE_DATABASE__", "true"))
  user_data_replace_on_change = true

  depends_on = [
    aws_route.private_a_nat,
    aws_route_table_association.private_backend_1a,
    aws_db_instance.this,
  ]

  tags = {
    Name = "${var.project_name}-backend-1a"
  }
}

resource "aws_instance" "backend_2" {
  ami                         = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type               = var.instance_type_backend
  subnet_id                   = aws_subnet.private_backend_1b.id
  vpc_security_group_ids      = [aws_security_group.backend.id]
  key_name                    = var.key_pair_name
  user_data_base64            = base64encode(replace(local.backend_user_data, "__INITIALIZE_DATABASE__", "false"))
  user_data_replace_on_change = true

  depends_on = [
    aws_route.private_b_nat,
    aws_route_table_association.private_backend_1b,
    aws_db_instance.this,
  ]

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
  storage_type      = "gp3"
  storage_encrypted = true

  vpc_security_group_ids = [aws_security_group.rds.id]
  db_subnet_group_name   = aws_db_subnet_group.this.name

  # MultiAZ habilitado: RDS provisiona automaticamente uma instância
  # standby síncrona na outra AZ do DB subnet group e faz failover
  # automático em caso de falha da AZ primária.
  # Custo: aprox. dobra o custo do RDS (instância + storage replicados).
  multi_az = true

  publicly_accessible     = false
  backup_retention_period = 7
  deletion_protection     = false # Setar false temporariamente para facilitar deleção do lab
  skip_final_snapshot     = true

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
    path     = "/"
    protocol = "HTTP"
    interval = 30
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
    path     = "/api/v1/health"
    protocol = "HTTP"
    interval = 30
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

    filter {} # regra se aplica a todos os objetos do bucket

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
