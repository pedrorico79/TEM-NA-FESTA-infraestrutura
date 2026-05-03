#!/bin/bash

# =============================================================
#  DEPLOY AUTOMATIZADO - ARQUITETURA 3 CAMADAS NA AWS
#  VPC: 10.0.0.0/24 | Região: us-east-1
#  Camadas: Frontend (Nginx+Node) | Backend (Java) | DB (MySQL)
#  + Bastion Host (acesso SSH às instâncias privadas)
# =============================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC}  $1"; }
log_ok()      { echo -e "${GREEN}[OK]${NC}    $1"; }
log_warn()    { echo -e "${YELLOW}[AVISO]${NC} $1"; }
log_error()   { echo -e "${RED}[ERRO]${NC}  $1"; exit 1; }
log_section() { echo -e "\n${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${YELLOW}  $1${NC}"; echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

# ================================================================
#  CONFIGURAÇÕES - EDITE ANTES DE EXECUTAR
# ================================================================

AWS_REGION="us-east-1"
PROJECT_NAME="minha-app"

AMI_ID=$(aws ec2 describe-images \
  --owners amazon \
  --filters "Name=name,Values=al2023-ami-*-x86_64" \
            "Name=architecture,Values=x86_64" \
            "Name=root-device-type,Values=ebs" \
  --query 'Images | sort_by(@, &CreationDate)[-1].ImageId' \
  --region "$AWS_REGION" \
  --output text)

INSTANCE_TYPE_FRONTEND="t3.micro"
INSTANCE_TYPE_BACKEND="t3.small"
INSTANCE_TYPE_DB="t3.small"
INSTANCE_TYPE_BASTION="t3.micro"

KEY_PAIR_NAME="myssh2"

BACKEND_PORT=8080

# IP de origem para SSH no Bastion.
# "0.0.0.0/0" = qualquer IP (apenas para testes).
# Para restringir ao seu IP: BASTION_SSH_CIDR="$(curl -s ifconfig.me)/32"
BASTION_SSH_CIDR="0.0.0.0/0"

# ================================================================
#  VERIFICAÇÕES INICIAIS
# ================================================================

log_section "Verificações iniciais"

if ! command -v aws &> /dev/null; then
    log_error "AWS CLI não encontrada. Instale em: https://aws.amazon.com/cli/"
fi

if ! aws sts get-caller-identity --region "$AWS_REGION" &> /dev/null; then
    log_error "Credenciais AWS inválidas. Execute: aws configure"
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)
log_ok "Conta AWS: $ACCOUNT_ID | Região: $AWS_REGION"

if ! aws ec2 describe-key-pairs --key-names "$KEY_PAIR_NAME" --region "$AWS_REGION" &> /dev/null; then
    log_error "Key Pair '$KEY_PAIR_NAME' não encontrado."
fi
log_ok "Key Pair '$KEY_PAIR_NAME' encontrado"
log_ok "AMI selecionada: $AMI_ID"

# ================================================================
#  1. VPC
# ================================================================

log_section "1/9 — Criando VPC (10.0.0.0/24)"

VPC_ID=$(aws ec2 create-vpc \
  --cidr-block "10.0.0.0/24" \
  --region "$AWS_REGION" \
  --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=${PROJECT_NAME}-vpc},{Key=Project,Value=${PROJECT_NAME}}]" \
  --query 'Vpc.VpcId' \
  --output text)

aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames "{\"Value\":true}"
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support "{\"Value\":true}"

log_ok "VPC criada: $VPC_ID"

# ================================================================
#  2. INTERNET GATEWAY
# ================================================================

log_section "2/9 — Criando Internet Gateway"

IGW_ID=$(aws ec2 create-internet-gateway \
  --region "$AWS_REGION" \
  --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=${PROJECT_NAME}-igw},{Key=Project,Value=${PROJECT_NAME}}]" \
  --query 'InternetGateway.InternetGatewayId' \
  --output text)

aws ec2 attach-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --vpc-id "$VPC_ID"

log_ok "Internet Gateway criado e anexado: $IGW_ID"

# ================================================================
#  3. SUB-REDES
# ================================================================

log_section "3/9 — Criando Sub-redes"

log_info "Criando sub-redes públicas..."

SUBNET_PUBLIC_1_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "10.0.0.0/26" \
  --availability-zone "${AWS_REGION}a" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${PROJECT_NAME}-public-nat-bastion-1a},{Key=Project,Value=${PROJECT_NAME}}]" \
  --query 'Subnet.SubnetId' \
  --output text)

SUBNET_PUBLIC_2_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "10.0.0.64/26" \
  --availability-zone "${AWS_REGION}b" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${PROJECT_NAME}-public-alb-1b},{Key=Project,Value=${PROJECT_NAME}}]" \
  --query 'Subnet.SubnetId' \
  --output text)

aws ec2 modify-subnet-attribute --subnet-id "$SUBNET_PUBLIC_1_ID" --map-public-ip-on-launch
aws ec2 modify-subnet-attribute --subnet-id "$SUBNET_PUBLIC_2_ID" --map-public-ip-on-launch

log_ok "Públicas: $SUBNET_PUBLIC_1_ID (1a) | $SUBNET_PUBLIC_2_ID (1b)"

log_info "Criando sub-redes privadas..."

SUBNET_PRIVATE_FRONT1_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "10.0.0.128/27" \
  --availability-zone "${AWS_REGION}a" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${PROJECT_NAME}-private-frontend-1a},{Key=Project,Value=${PROJECT_NAME}}]" \
  --query 'Subnet.SubnetId' \
  --output text)

SUBNET_PRIVATE_FRONT2_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "10.0.0.160/27" \
  --availability-zone "${AWS_REGION}b" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${PROJECT_NAME}-private-frontend-1b},{Key=Project,Value=${PROJECT_NAME}}]" \
  --query 'Subnet.SubnetId' \
  --output text)

SUBNET_PRIVATE_BACKEND_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "10.0.0.192/27" \
  --availability-zone "${AWS_REGION}a" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${PROJECT_NAME}-private-backend-1a},{Key=Project,Value=${PROJECT_NAME}}]" \
  --query 'Subnet.SubnetId' \
  --output text)

SUBNET_PRIVATE_DB_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "10.0.0.224/27" \
  --availability-zone "${AWS_REGION}a" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${PROJECT_NAME}-private-db-1a},{Key=Project,Value=${PROJECT_NAME}}]" \
  --query 'Subnet.SubnetId' \
  --output text)

log_ok "Frontend-1: $SUBNET_PRIVATE_FRONT1_ID | Frontend-2: $SUBNET_PRIVATE_FRONT2_ID"
log_ok "Backend:    $SUBNET_PRIVATE_BACKEND_ID | DB: $SUBNET_PRIVATE_DB_ID"

# ================================================================
#  4. NAT GATEWAY + ELASTIC IP
# ================================================================

log_section "4/9 — Criando NAT Gateway (com Elastic IP)"

EIP_ALLOC_ID=$(aws ec2 allocate-address \
  --domain vpc \
  --region "$AWS_REGION" \
  --query 'AllocationId' \
  --output text)

NAT_GW_ID=$(aws ec2 create-nat-gateway \
  --subnet-id "$SUBNET_PUBLIC_1_ID" \
  --allocation-id "$EIP_ALLOC_ID" \
  --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=${PROJECT_NAME}-nat-gw},{Key=Project,Value=${PROJECT_NAME}}]" \
  --query 'NatGateway.NatGatewayId' \
  --output text)

log_info "Aguardando NAT Gateway ficar disponível (~90s)..."
aws ec2 wait nat-gateway-available \
  --nat-gateway-ids "$NAT_GW_ID" \
  --region "$AWS_REGION"

log_ok "NAT Gateway disponível: $NAT_GW_ID | EIP: $EIP_ALLOC_ID"

# ================================================================
#  5. ROUTE TABLES
# ================================================================

log_section "5/9 — Configurando Tabelas de Roteamento"

RT_PUBLIC_ID=$(aws ec2 create-route-table \
  --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${PROJECT_NAME}-rt-public},{Key=Project,Value=${PROJECT_NAME}}]" \
  --query 'RouteTable.RouteTableId' \
  --output text)

aws ec2 create-route \
  --route-table-id "$RT_PUBLIC_ID" \
  --destination-cidr-block "0.0.0.0/0" \
  --gateway-id "$IGW_ID" > /dev/null

aws ec2 associate-route-table --route-table-id "$RT_PUBLIC_ID" --subnet-id "$SUBNET_PUBLIC_1_ID" > /dev/null
aws ec2 associate-route-table --route-table-id "$RT_PUBLIC_ID" --subnet-id "$SUBNET_PUBLIC_2_ID" > /dev/null

log_ok "Route Table Pública: $RT_PUBLIC_ID → IGW"

RT_PRIVATE_ID=$(aws ec2 create-route-table \
  --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${PROJECT_NAME}-rt-private},{Key=Project,Value=${PROJECT_NAME}}]" \
  --query 'RouteTable.RouteTableId' \
  --output text)

aws ec2 create-route \
  --route-table-id "$RT_PRIVATE_ID" \
  --destination-cidr-block "0.0.0.0/0" \
  --nat-gateway-id "$NAT_GW_ID" > /dev/null

aws ec2 associate-route-table --route-table-id "$RT_PRIVATE_ID" --subnet-id "$SUBNET_PRIVATE_FRONT1_ID"  > /dev/null
aws ec2 associate-route-table --route-table-id "$RT_PRIVATE_ID" --subnet-id "$SUBNET_PRIVATE_FRONT2_ID"  > /dev/null
aws ec2 associate-route-table --route-table-id "$RT_PRIVATE_ID" --subnet-id "$SUBNET_PRIVATE_BACKEND_ID" > /dev/null
aws ec2 associate-route-table --route-table-id "$RT_PRIVATE_ID" --subnet-id "$SUBNET_PRIVATE_DB_ID"      > /dev/null

log_ok "Route Table Privada: $RT_PRIVATE_ID → NAT Gateway (4 sub-redes)"

# ================================================================
#  6. SECURITY GROUPS
# ================================================================

log_section "6/9 — Criando Security Groups"

# ----------------------------------------------------------------
# [NOVO] SG Bastion — SSH externo (seu IP ou 0.0.0.0/0)
# ----------------------------------------------------------------
SG_BASTION_ID=$(aws ec2 create-security-group \
  --group-name "${PROJECT_NAME}-sg-bastion" \
  --description "Bastion: SSH externo para acesso as instancias privadas" \
  --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${PROJECT_NAME}-sg-bastion},{Key=Project,Value=${PROJECT_NAME}}]" \
  --query 'GroupId' \
  --output text)

aws ec2 authorize-security-group-ingress --group-id "$SG_BASTION_ID" \
  --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":22,\"ToPort\":22,\"IpRanges\":[{\"CidrIp\":\"${BASTION_SSH_CIDR}\",\"Description\":\"SSH externo\"}]}]"

log_ok "SG Bastion: $SG_BASTION_ID"

# SG ALB — HTTP e HTTPS da internet
SG_ALB_ID=$(aws ec2 create-security-group \
  --group-name "${PROJECT_NAME}-sg-alb" \
  --description "ALB: permite HTTP e HTTPS da internet" \
  --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${PROJECT_NAME}-sg-alb},{Key=Project,Value=${PROJECT_NAME}}]" \
  --query 'GroupId' \
  --output text)

aws ec2 authorize-security-group-ingress --group-id "$SG_ALB_ID" \
  --ip-permissions '[{"IpProtocol":"tcp","FromPort":80,"ToPort":80,"IpRanges":[{"CidrIp":"0.0.0.0/0","Description":"HTTP publico"}]}]'
aws ec2 authorize-security-group-ingress --group-id "$SG_ALB_ID" \
  --ip-permissions '[{"IpProtocol":"tcp","FromPort":443,"ToPort":443,"IpRanges":[{"CidrIp":"0.0.0.0/0","Description":"HTTPS publico"}]}]'

log_ok "SG ALB: $SG_ALB_ID"

# ----------------------------------------------------------------
# SG Frontend — HTTP do ALB + SSH do Bastion
# ----------------------------------------------------------------
SG_FRONTEND_ID=$(aws ec2 create-security-group \
  --group-name "${PROJECT_NAME}-sg-frontend" \
  --description "Frontend: HTTP do ALB e SSH do Bastion" \
  --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${PROJECT_NAME}-sg-frontend},{Key=Project,Value=${PROJECT_NAME}}]" \
  --query 'GroupId' \
  --output text)

aws ec2 authorize-security-group-ingress --group-id "$SG_FRONTEND_ID" \
  --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":80,\"ToPort\":80,\"UserIdGroupPairs\":[{\"GroupId\":\"$SG_ALB_ID\",\"Description\":\"HTTP do ALB\"}]}]"

# [NOVO] SSH apenas a partir do SG do Bastion
aws ec2 authorize-security-group-ingress --group-id "$SG_FRONTEND_ID" \
  --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":22,\"ToPort\":22,\"UserIdGroupPairs\":[{\"GroupId\":\"$SG_BASTION_ID\",\"Description\":\"SSH do Bastion\"}]}]"

log_ok "SG Frontend: $SG_FRONTEND_ID"

# ----------------------------------------------------------------
# SG Backend — porta da app do Frontend + SSH do Bastion
# ----------------------------------------------------------------
SG_BACKEND_ID=$(aws ec2 create-security-group \
  --group-name "${PROJECT_NAME}-sg-backend" \
  --description "Backend: porta app do Frontend e SSH do Bastion" \
  --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${PROJECT_NAME}-sg-backend},{Key=Project,Value=${PROJECT_NAME}}]" \
  --query 'GroupId' \
  --output text)

aws ec2 authorize-security-group-ingress --group-id "$SG_BACKEND_ID" \
  --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":${BACKEND_PORT},\"ToPort\":${BACKEND_PORT},\"UserIdGroupPairs\":[{\"GroupId\":\"$SG_FRONTEND_ID\",\"Description\":\"App do Frontend\"}]}]"

# [NOVO] SSH apenas a partir do SG do Bastion
aws ec2 authorize-security-group-ingress --group-id "$SG_BACKEND_ID" \
  --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":22,\"ToPort\":22,\"UserIdGroupPairs\":[{\"GroupId\":\"$SG_BASTION_ID\",\"Description\":\"SSH do Bastion\"}]}]"

log_ok "SG Backend: $SG_BACKEND_ID"

# ----------------------------------------------------------------
# SG DB — MySQL do Backend + SSH do Bastion
# ----------------------------------------------------------------
SG_DB_ID=$(aws ec2 create-security-group \
  --group-name "${PROJECT_NAME}-sg-db" \
  --description "DB: MySQL do Backend e SSH do Bastion" \
  --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${PROJECT_NAME}-sg-db},{Key=Project,Value=${PROJECT_NAME}}]" \
  --query 'GroupId' \
  --output text)

aws ec2 authorize-security-group-ingress --group-id "$SG_DB_ID" \
  --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":3306,\"ToPort\":3306,\"UserIdGroupPairs\":[{\"GroupId\":\"$SG_BACKEND_ID\",\"Description\":\"MySQL do Backend\"}]}]"

# [NOVO] SSH apenas a partir do SG do Bastion
aws ec2 authorize-security-group-ingress --group-id "$SG_DB_ID" \
  --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":22,\"ToPort\":22,\"UserIdGroupPairs\":[{\"GroupId\":\"$SG_BASTION_ID\",\"Description\":\"SSH do Bastion\"}]}]"

log_ok "SG Banco de Dados: $SG_DB_ID"

# ================================================================
#  7. INSTÂNCIAS EC2
# ================================================================

log_section "7/9 — Criando Instâncias EC2"

FRONTEND_USER_DATA=$(cat <<'USERDATA'
#!/bin/bash
set -e
dnf update -y
dnf install -y nginx
systemctl enable --now nginx

curl -fsSL https://rpm.nodesource.com/setup_18.x | bash -
dnf install -y nodejs

cat > /usr/share/nginx/html/index.html <<HTML
<!DOCTYPE html>
<html>
<head><title>Frontend - Minha App</title></head>
<body>
  <h1>Frontend funcionando!</h1>
  <h2>Servidor: $(hostname)</h2>
  <h3>IP: $(hostname -I)</h3>
</body>
</html>
HTML

systemctl restart nginx
echo "Frontend configurado com sucesso" >> /var/log/deploy.log
USERDATA
)

BACKEND_USER_DATA=$(cat <<'USERDATA'
#!/bin/bash
set -e
dnf update -y
dnf install -y java-17-amazon-corretto java-17-amazon-corretto-devel maven
mkdir -p /opt/app
chown ec2-user:ec2-user /opt/app
echo "Backend (Java/Spring) configurado" >> /var/log/deploy.log
java -version >> /var/log/deploy.log 2>&1
USERDATA
)

DB_USER_DATA=$(cat <<'USERDATA'
#!/bin/bash
set -e
dnf update -y
dnf install -y mysql-server
systemctl enable --now mysqld
sleep 10

mysql -u root <<'SQL'
ALTER USER 'root'@'localhost' IDENTIFIED BY 'SenhaRoot@2025!';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
CREATE DATABASE IF NOT EXISTS app_db CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'app_user'@'%' IDENTIFIED BY 'AppUser@2025!';
GRANT ALL PRIVILEGES ON app_db.* TO 'app_user'@'%';
FLUSH PRIVILEGES;
SQL

echo "MySQL configurado com sucesso" >> /var/log/deploy.log
USERDATA
)

log_info "Iniciando instâncias..."

INSTANCE_FRONTEND_1_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type "$INSTANCE_TYPE_FRONTEND" \
  --subnet-id "$SUBNET_PRIVATE_FRONT1_ID" \
  --security-group-ids "$SG_FRONTEND_ID" \
  --key-name "$KEY_PAIR_NAME" \
  --user-data "$FRONTEND_USER_DATA" \
  --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":20,"VolumeType":"gp3","DeleteOnTermination":true}}]' \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${PROJECT_NAME}-frontend-1},{Key=Project,Value=${PROJECT_NAME}},{Key=Layer,Value=frontend}]" \
  --query 'Instances[0].InstanceId' \
  --output text)

INSTANCE_FRONTEND_2_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type "$INSTANCE_TYPE_FRONTEND" \
  --subnet-id "$SUBNET_PRIVATE_FRONT2_ID" \
  --security-group-ids "$SG_FRONTEND_ID" \
  --key-name "$KEY_PAIR_NAME" \
  --user-data "$FRONTEND_USER_DATA" \
  --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":20,"VolumeType":"gp3","DeleteOnTermination":true}}]' \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${PROJECT_NAME}-frontend-2},{Key=Project,Value=${PROJECT_NAME}},{Key=Layer,Value=frontend}]" \
  --query 'Instances[0].InstanceId' \
  --output text)

INSTANCE_BACKEND_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type "$INSTANCE_TYPE_BACKEND" \
  --subnet-id "$SUBNET_PRIVATE_BACKEND_ID" \
  --security-group-ids "$SG_BACKEND_ID" \
  --key-name "$KEY_PAIR_NAME" \
  --user-data "$BACKEND_USER_DATA" \
  --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":30,"VolumeType":"gp3","DeleteOnTermination":true}}]' \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${PROJECT_NAME}-backend},{Key=Project,Value=${PROJECT_NAME}},{Key=Layer,Value=backend}]" \
  --query 'Instances[0].InstanceId' \
  --output text)

INSTANCE_DB_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type "$INSTANCE_TYPE_DB" \
  --subnet-id "$SUBNET_PRIVATE_DB_ID" \
  --security-group-ids "$SG_DB_ID" \
  --key-name "$KEY_PAIR_NAME" \
  --user-data "$DB_USER_DATA" \
  --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":50,"VolumeType":"gp3","DeleteOnTermination":true}}]' \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${PROJECT_NAME}-db},{Key=Project,Value=${PROJECT_NAME}},{Key=Layer,Value=database}]" \
  --query 'Instances[0].InstanceId' \
  --output text)

# ----------------------------------------------------------------
# [NOVO] Bastion Host — sub-rede pública 1a, IP público atribuído
# ----------------------------------------------------------------
INSTANCE_BASTION_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type "$INSTANCE_TYPE_BASTION" \
  --subnet-id "$SUBNET_PUBLIC_1_ID" \
  --security-group-ids "$SG_BASTION_ID" \
  --key-name "$KEY_PAIR_NAME" \
  --associate-public-ip-address \
  --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":8,"VolumeType":"gp3","DeleteOnTermination":true}}]' \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${PROJECT_NAME}-bastion},{Key=Project,Value=${PROJECT_NAME}},{Key=Layer,Value=bastion}]" \
  --query 'Instances[0].InstanceId' \
  --output text)

log_info "Aguardando todas as instâncias ficarem 'running'..."
aws ec2 wait instance-running \
  --instance-ids "$INSTANCE_FRONTEND_1_ID" "$INSTANCE_FRONTEND_2_ID" "$INSTANCE_BACKEND_ID" "$INSTANCE_DB_ID" "$INSTANCE_BASTION_ID" \
  --region "$AWS_REGION"

log_ok "Frontend 1:     $INSTANCE_FRONTEND_1_ID"
log_ok "Frontend 2:     $INSTANCE_FRONTEND_2_ID"
log_ok "Backend:        $INSTANCE_BACKEND_ID"
log_ok "Banco de Dados: $INSTANCE_DB_ID"
log_ok "Bastion Host:   $INSTANCE_BASTION_ID"

# ================================================================
#  8. TARGET GROUP + ALB
# ================================================================

log_section "8/9 — Criando Target Group e Application Load Balancer"

TG_ARN=$(aws elbv2 create-target-group \
  --name "${PROJECT_NAME}-tg-frontend" \
  --protocol HTTP \
  --port 80 \
  --vpc-id "$VPC_ID" \
  --target-type instance \
  --health-check-protocol HTTP \
  --health-check-path "/" \
  --health-check-interval-seconds 30 \
  --health-check-timeout-seconds 5 \
  --healthy-threshold-count 2 \
  --unhealthy-threshold-count 3 \
  --tags "Key=Name,Value=${PROJECT_NAME}-tg-frontend" "Key=Project,Value=${PROJECT_NAME}" \
  --query 'TargetGroups[0].TargetGroupArn' \
  --output text)

aws elbv2 register-targets \
  --target-group-arn "$TG_ARN" \
  --targets "Id=$INSTANCE_FRONTEND_1_ID,Port=80" "Id=$INSTANCE_FRONTEND_2_ID,Port=80"

log_ok "Target Group criado: $TG_ARN"

ALB_ARN=$(aws elbv2 create-load-balancer \
  --name "${PROJECT_NAME}-alb" \
  --subnets "$SUBNET_PUBLIC_1_ID" "$SUBNET_PUBLIC_2_ID" \
  --security-groups "$SG_ALB_ID" \
  --scheme internet-facing \
  --type application \
  --ip-address-type ipv4 \
  --tags "Key=Name,Value=${PROJECT_NAME}-alb" "Key=Project,Value=${PROJECT_NAME}" \
  --query 'LoadBalancers[0].LoadBalancerArn' \
  --output text)

LISTENER_ARN=$(aws elbv2 create-listener \
  --load-balancer-arn "$ALB_ARN" \
  --protocol HTTP \
  --port 80 \
  --default-actions "Type=forward,TargetGroupArn=$TG_ARN" \
  --tags "Key=Name,Value=${PROJECT_NAME}-listener-http" "Key=Project,Value=${PROJECT_NAME}" \
  --query 'Listeners[0].ListenerArn' \
  --output text)

log_info "Aguardando ALB ficar ativo (~2 minutos)..."
aws elbv2 wait load-balancer-available \
  --load-balancer-arns "$ALB_ARN"

ALB_DNS=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns "$ALB_ARN" \
  --query 'LoadBalancers[0].DNSName' \
  --output text)

log_ok "ALB ativo: $ALB_DNS"

# ================================================================
#  9. INFORMAÇÕES FINAIS
# ================================================================

log_section "9/9 — Coletando informações finais"

IP_FRONTEND_1=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_FRONTEND_1_ID" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' \
  --output text)

IP_FRONTEND_2=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_FRONTEND_2_ID" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' \
  --output text)

IP_BACKEND=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_BACKEND_ID" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' \
  --output text)

IP_DB=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_DB_ID" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' \
  --output text)

IP_BASTION_PUBLIC=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_BASTION_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)

IP_BASTION_PRIVATE=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_BASTION_ID" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' \
  --output text)

# ================================================================
#  RESUMO FINAL
# ================================================================

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║         DEPLOY CONCLUÍDO COM SUCESSO!               ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BLUE}  REDE${NC}"
echo    "  ├─ VPC:               $VPC_ID  (10.0.0.0/24)"
echo    "  ├─ Internet Gateway:  $IGW_ID"
echo    "  └─ NAT Gateway:       $NAT_GW_ID"
echo ""
echo -e "${BLUE}  SUB-REDES${NC}"
echo    "  ├─ Pública NAT+Bastion (1a):  $SUBNET_PUBLIC_1_ID  (10.0.0.0/26)"
echo    "  ├─ Pública ALB (1b):          $SUBNET_PUBLIC_2_ID  (10.0.0.64/26)"
echo    "  ├─ Privada Front-1:           $SUBNET_PRIVATE_FRONT1_ID  (10.0.0.128/27)"
echo    "  ├─ Privada Front-2:           $SUBNET_PRIVATE_FRONT2_ID  (10.0.0.160/27)"
echo    "  ├─ Privada Backend:           $SUBNET_PRIVATE_BACKEND_ID  (10.0.0.192/27)"
echo    "  └─ Privada DB:                $SUBNET_PRIVATE_DB_ID  (10.0.0.224/27)"
echo ""
echo -e "${BLUE}  INSTÂNCIAS EC2${NC}"
echo    "  ├─ Bastion  [pub: $IP_BASTION_PUBLIC | priv: $IP_BASTION_PRIVATE]:  $INSTANCE_BASTION_ID"
echo    "  ├─ Frontend 1  [$IP_FRONTEND_1]:  $INSTANCE_FRONTEND_1_ID"
echo    "  ├─ Frontend 2  [$IP_FRONTEND_2]:  $INSTANCE_FRONTEND_2_ID"
echo    "  ├─ Backend     [$IP_BACKEND]:  $INSTANCE_BACKEND_ID"
echo    "  └─ DB MySQL    [$IP_DB]:  $INSTANCE_DB_ID"
echo ""
echo -e "${BLUE}  LOAD BALANCER${NC}"
echo    "  └─ DNS: $ALB_DNS"
echo ""
echo -e "${YELLOW}  ▶  Aplicação: http://$ALB_DNS${NC}"
echo ""
echo -e "${GREEN}  ── COMO ACESSAR VIA SSH ──────────────────────────────${NC}"
echo ""
echo    "  Opção A — SSH Agent Forwarding (recomendado, chave fica só no seu PC):"
echo    "    ssh -A -i ~/.ssh/${KEY_PAIR_NAME}.pem ec2-user@${IP_BASTION_PUBLIC}  # entra no Bastion"
echo    "    ssh ec2-user@${IP_FRONTEND_1}   # Frontend 1  (a partir do Bastion)"
echo    "    ssh ec2-user@${IP_FRONTEND_2}   # Frontend 2  (a partir do Bastion)"
echo    "    ssh ec2-user@${IP_BACKEND}      # Backend     (a partir do Bastion)"
echo    "    ssh ec2-user@${IP_DB}           # DB MySQL    (a partir do Bastion)"
echo ""
echo    "  Opção B — ProxyJump (acesso direto em um único comando do seu PC):"
echo    "    ssh -J ec2-user@${IP_BASTION_PUBLIC} -i ~/.ssh/${KEY_PAIR_NAME}.pem ec2-user@${IP_FRONTEND_1}"
echo    "    ssh -J ec2-user@${IP_BASTION_PUBLIC} -i ~/.ssh/${KEY_PAIR_NAME}.pem ec2-user@${IP_BACKEND}"
echo    "    ssh -J ec2-user@${IP_BASTION_PUBLIC} -i ~/.ssh/${KEY_PAIR_NAME}.pem ec2-user@${IP_DB}"
echo ""
echo -e "${YELLOW}  ⚠  ATENÇÃO:${NC}"
echo    "  • Aguarde ~3-5 minutos para o user-data finalizar nas instâncias."
echo    "  • Altere as senhas padrão do MySQL antes de ir para produção!"
echo    "  • Para maior segurança, defina BASTION_SSH_CIDR com seu IP fixo."
echo    "  • Considere HTTPS no ALB via AWS Certificate Manager."
echo ""

SUMMARY_FILE="deploy_summary_$(date +%Y%m%d_%H%M%S).txt"
cat > "$SUMMARY_FILE" <<SUMMARY
=== RESUMO DO DEPLOY - $(date) ===

VPC_ID=$VPC_ID
IGW_ID=$IGW_ID
NAT_GW_ID=$NAT_GW_ID
EIP_ALLOC_ID=$EIP_ALLOC_ID

SUBNET_PUBLIC_1=$SUBNET_PUBLIC_1_ID
SUBNET_PUBLIC_2=$SUBNET_PUBLIC_2_ID
SUBNET_PRIVATE_FRONT1=$SUBNET_PRIVATE_FRONT1_ID
SUBNET_PRIVATE_FRONT2=$SUBNET_PRIVATE_FRONT2_ID
SUBNET_PRIVATE_BACKEND=$SUBNET_PRIVATE_BACKEND_ID
SUBNET_PRIVATE_DB=$SUBNET_PRIVATE_DB_ID

SG_BASTION=$SG_BASTION_ID
SG_ALB=$SG_ALB_ID
SG_FRONTEND=$SG_FRONTEND_ID
SG_BACKEND=$SG_BACKEND_ID
SG_DB=$SG_DB_ID

INSTANCE_BASTION=$INSTANCE_BASTION_ID  (pub=$IP_BASTION_PUBLIC | priv=$IP_BASTION_PRIVATE)
INSTANCE_FRONTEND_1=$INSTANCE_FRONTEND_1_ID ($IP_FRONTEND_1)
INSTANCE_FRONTEND_2=$INSTANCE_FRONTEND_2_ID ($IP_FRONTEND_2)
INSTANCE_BACKEND=$INSTANCE_BACKEND_ID ($IP_BACKEND)
INSTANCE_DB=$INSTANCE_DB_ID ($IP_DB)

ALB_ARN=$ALB_ARN
ALB_DNS=$ALB_DNS
TG_ARN=$TG_ARN

URL=http://$ALB_DNS

# SSH — Agent Forwarding
SSH_BASTION=ssh -A -i ~/.ssh/${KEY_PAIR_NAME}.pem ec2-user@${IP_BASTION_PUBLIC}
SSH_FRONTEND_1=ssh ec2-user@${IP_FRONTEND_1}
SSH_FRONTEND_2=ssh ec2-user@${IP_FRONTEND_2}
SSH_BACKEND=ssh ec2-user@${IP_BACKEND}
SSH_DB=ssh ec2-user@${IP_DB}

# SSH — ProxyJump (direto do seu PC)
JUMP_FRONTEND_1=ssh -J ec2-user@${IP_BASTION_PUBLIC} -i ~/.ssh/${KEY_PAIR_NAME}.pem ec2-user@${IP_FRONTEND_1}
JUMP_BACKEND=ssh -J ec2-user@${IP_BASTION_PUBLIC} -i ~/.ssh/${KEY_PAIR_NAME}.pem ec2-user@${IP_BACKEND}
JUMP_DB=ssh -J ec2-user@${IP_BASTION_PUBLIC} -i ~/.ssh/${KEY_PAIR_NAME}.pem ec2-user@${IP_DB}
SUMMARY

log_ok "Resumo e comandos SSH salvos em: $SUMMARY_FILE"
echo ""
