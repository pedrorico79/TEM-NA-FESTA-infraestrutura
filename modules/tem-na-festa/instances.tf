# EC2 instances and user-data locals

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
    ./mvnw --batch-mode -Dmaven.test.skip=true clean package

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
