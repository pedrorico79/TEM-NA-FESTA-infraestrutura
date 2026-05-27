#!/bin/bash

# =============================================================
#  DEPLOY AUTOMATIZADO - ARQUITETURA 3 CAMADAS NA AWS
#  VPC: 10.0.0.0/24 | Região: us-east-1
#  Camadas: Frontend (Nginx) + EFS | Backend Java (2 AZs) | RDS MySQL
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
  --owners 099720109477 \
  --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" \
            "Name=architecture,Values=x86_64" \
            "Name=root-device-type,Values=ebs" \
            "Name=state,Values=available" \
  --query 'Images | sort_by(@, &CreationDate)[-1].ImageId' \
  --region "$AWS_REGION" \
  --output text)

INSTANCE_TYPE_FRONTEND="t3.micro"
INSTANCE_TYPE_BACKEND="t3.small"
INSTANCE_TYPE_BASTION="t3.micro"

KEY_PAIR_NAME="myssh"

BACKEND_PORT=8080

# RDS
DB_INSTANCE_CLASS="db.t3.micro"
DB_NAME="tem_na_festa"
DB_MASTER_USER="admin"
DB_MASTER_PASSWORD="TnaFesta2025!"   # ← altere antes de ir para produção

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

log_section "1/11 — Criando VPC (10.0.0.0/24)"

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

log_section "2/11 — Criando Internet Gateway"

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
#
#  Mapa de endereçamento (10.0.0.0/24 = 256 endereços):
#  10.0.0.0/26   → pública  NAT+Bastion  (1a)  – 64 hosts
#  10.0.0.64/26  → pública  ALB          (1b)  – 64 hosts
#  10.0.0.128/28 → privada  Frontend     (1a)  – 16 hosts
#  10.0.0.144/28 → privada  Frontend     (1b)  – 16 hosts
#  10.0.0.160/28 → privada  Backend      (1a)  – 16 hosts
#  10.0.0.176/28 → privada  Backend      (1b)  – 16 hosts  ← novo
#  10.0.0.192/28 → privada  RDS primário (1a)  – 16 hosts
#  10.0.0.208/28 → privada  RDS standby  (1b)  – 16 hosts  ← novo (subnet group RDS)
# ================================================================

log_section "3/11 — Criando Sub-redes"

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
  --cidr-block "10.0.0.128/28" \
  --availability-zone "${AWS_REGION}a" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${PROJECT_NAME}-private-frontend-1a},{Key=Project,Value=${PROJECT_NAME}}]" \
  --query 'Subnet.SubnetId' \
  --output text)

SUBNET_PRIVATE_FRONT2_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "10.0.0.144/28" \
  --availability-zone "${AWS_REGION}b" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${PROJECT_NAME}-private-frontend-1b},{Key=Project,Value=${PROJECT_NAME}}]" \
  --query 'Subnet.SubnetId' \
  --output text)

SUBNET_PRIVATE_BACKEND1_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "10.0.0.160/28" \
  --availability-zone "${AWS_REGION}a" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${PROJECT_NAME}-private-backend-1a},{Key=Project,Value=${PROJECT_NAME}}]" \
  --query 'Subnet.SubnetId' \
  --output text)

SUBNET_PRIVATE_BACKEND2_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "10.0.0.176/28" \
  --availability-zone "${AWS_REGION}b" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${PROJECT_NAME}-private-backend-1b},{Key=Project,Value=${PROJECT_NAME}}]" \
  --query 'Subnet.SubnetId' \
  --output text)

SUBNET_PRIVATE_DB1_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "10.0.0.192/28" \
  --availability-zone "${AWS_REGION}a" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${PROJECT_NAME}-private-rds-1a},{Key=Project,Value=${PROJECT_NAME}}]" \
  --query 'Subnet.SubnetId' \
  --output text)

SUBNET_PRIVATE_DB2_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "10.0.0.208/28" \
  --availability-zone "${AWS_REGION}b" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${PROJECT_NAME}-private-rds-1b},{Key=Project,Value=${PROJECT_NAME}}]" \
  --query 'Subnet.SubnetId' \
  --output text)

log_ok "Frontend-1a: $SUBNET_PRIVATE_FRONT1_ID | Frontend-1b: $SUBNET_PRIVATE_FRONT2_ID"
log_ok "Backend-1a:  $SUBNET_PRIVATE_BACKEND1_ID | Backend-1b:  $SUBNET_PRIVATE_BACKEND2_ID"
log_ok "RDS-1a:      $SUBNET_PRIVATE_DB1_ID | RDS-1b:      $SUBNET_PRIVATE_DB2_ID"

# ================================================================
#  4. NAT GATEWAY + ELASTIC IP
# ================================================================

log_section "4/11 — Criando NAT Gateway (com Elastic IP)"

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

log_section "5/11 — Configurando Tabelas de Roteamento"

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

aws ec2 associate-route-table --route-table-id "$RT_PRIVATE_ID" --subnet-id "$SUBNET_PRIVATE_FRONT1_ID"    > /dev/null
aws ec2 associate-route-table --route-table-id "$RT_PRIVATE_ID" --subnet-id "$SUBNET_PRIVATE_FRONT2_ID"    > /dev/null
aws ec2 associate-route-table --route-table-id "$RT_PRIVATE_ID" --subnet-id "$SUBNET_PRIVATE_BACKEND1_ID"  > /dev/null
aws ec2 associate-route-table --route-table-id "$RT_PRIVATE_ID" --subnet-id "$SUBNET_PRIVATE_BACKEND2_ID"  > /dev/null
aws ec2 associate-route-table --route-table-id "$RT_PRIVATE_ID" --subnet-id "$SUBNET_PRIVATE_DB1_ID"       > /dev/null
aws ec2 associate-route-table --route-table-id "$RT_PRIVATE_ID" --subnet-id "$SUBNET_PRIVATE_DB2_ID"       > /dev/null

log_ok "Route Table Privada: $RT_PRIVATE_ID → NAT Gateway (6 sub-redes)"

# ================================================================
#  6. SECURITY GROUPS
# ================================================================

log_section "6/11 — Criando Security Groups"

# ── Bastion ───────────────────────────────────────────────────
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

# ── ALB ───────────────────────────────────────────────────────
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

# ── Frontend ──────────────────────────────────────────────────
SG_FRONTEND_ID=$(aws ec2 create-security-group \
  --group-name "${PROJECT_NAME}-sg-frontend" \
  --description "Frontend: HTTP do ALB e SSH do Bastion" \
  --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${PROJECT_NAME}-sg-frontend},{Key=Project,Value=${PROJECT_NAME}}]" \
  --query 'GroupId' \
  --output text)

aws ec2 authorize-security-group-ingress --group-id "$SG_FRONTEND_ID" \
  --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":80,\"ToPort\":80,\"UserIdGroupPairs\":[{\"GroupId\":\"$SG_ALB_ID\",\"Description\":\"HTTP do ALB\"}]}]"
aws ec2 authorize-security-group-ingress --group-id "$SG_FRONTEND_ID" \
  --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":22,\"ToPort\":22,\"UserIdGroupPairs\":[{\"GroupId\":\"$SG_BASTION_ID\",\"Description\":\"SSH do Bastion\"}]}]"

log_ok "SG Frontend: $SG_FRONTEND_ID"

# ── EFS ───────────────────────────────────────────────────────
SG_EFS_ID=$(aws ec2 create-security-group \
  --group-name "${PROJECT_NAME}-sg-efs" \
  --description "EFS: NFS somente a partir das instancias Frontend" \
  --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${PROJECT_NAME}-sg-efs},{Key=Project,Value=${PROJECT_NAME}}]" \
  --query 'GroupId' \
  --output text)

aws ec2 authorize-security-group-ingress --group-id "$SG_EFS_ID" \
  --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":2049,\"ToPort\":2049,\"UserIdGroupPairs\":[{\"GroupId\":\"$SG_FRONTEND_ID\",\"Description\":\"NFS do Frontend\"}]}]"

log_ok "SG EFS: $SG_EFS_ID"

# ── Backend ───────────────────────────────────────────────────
SG_BACKEND_ID=$(aws ec2 create-security-group \
  --group-name "${PROJECT_NAME}-sg-backend" \
  --description "Backend: porta app do Frontend e SSH do Bastion" \
  --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${PROJECT_NAME}-sg-backend},{Key=Project,Value=${PROJECT_NAME}}]" \
  --query 'GroupId' \
  --output text)

aws ec2 authorize-security-group-ingress --group-id "$SG_BACKEND_ID" \
  --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":${BACKEND_PORT},\"ToPort\":${BACKEND_PORT},\"UserIdGroupPairs\":[{\"GroupId\":\"$SG_FRONTEND_ID\",\"Description\":\"App do Frontend\"}]}]"
aws ec2 authorize-security-group-ingress --group-id "$SG_BACKEND_ID" \
  --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":22,\"ToPort\":22,\"UserIdGroupPairs\":[{\"GroupId\":\"$SG_BASTION_ID\",\"Description\":\"SSH do Bastion\"}]}]"

log_ok "SG Backend: $SG_BACKEND_ID"

# ── RDS ───────────────────────────────────────────────────────
SG_RDS_ID=$(aws ec2 create-security-group \
  --group-name "${PROJECT_NAME}-sg-rds" \
  --description "RDS: MySQL somente a partir do Backend" \
  --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${PROJECT_NAME}-sg-rds},{Key=Project,Value=${PROJECT_NAME}}]" \
  --query 'GroupId' \
  --output text)

aws ec2 authorize-security-group-ingress --group-id "$SG_RDS_ID" \
  --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":3306,\"ToPort\":3306,\"UserIdGroupPairs\":[{\"GroupId\":\"$SG_BACKEND_ID\",\"Description\":\"MySQL do Backend\"}]}]"

log_ok "SG RDS: $SG_RDS_ID"

# ================================================================
#  7. EFS — Sistema de arquivos compartilhado entre os Frontends
# ================================================================

log_section "7/11 — Criando EFS (compartilhado entre os Frontends)"

EFS_ID=$(aws efs create-file-system \
  --region "$AWS_REGION" \
  --performance-mode generalPurpose \
  --throughput-mode bursting \
  --encrypted \
  --tags "Key=Name,Value=${PROJECT_NAME}-efs" "Key=Project,Value=${PROJECT_NAME}" \
  --query 'FileSystemId' \
  --output text)

log_info "Aguardando EFS ficar disponível..."
for i in $(seq 1 18); do
  EFS_STATE=$(aws efs describe-file-systems \
    --file-system-id "$EFS_ID" \
    --region "$AWS_REGION" \
    --query 'FileSystems[0].LifeCycleState' \
    --output text)
  if [[ "$EFS_STATE" == "available" ]]; then
    break
  fi
  log_info "  EFS: $EFS_STATE — aguardando 10s... ($i/18)"
  sleep 10
done

log_ok "EFS criado: $EFS_ID"

log_info "Criando Mount Targets nas sub-redes privadas de Frontend..."

MT_FRONT1_ID=$(aws efs create-mount-target \
  --file-system-id "$EFS_ID" \
  --subnet-id "$SUBNET_PRIVATE_FRONT1_ID" \
  --security-groups "$SG_EFS_ID" \
  --query 'MountTargetId' \
  --output text)

MT_FRONT2_ID=$(aws efs create-mount-target \
  --file-system-id "$EFS_ID" \
  --subnet-id "$SUBNET_PRIVATE_FRONT2_ID" \
  --security-groups "$SG_EFS_ID" \
  --query 'MountTargetId' \
  --output text)

log_ok "Mount Targets: $MT_FRONT1_ID (1a) | $MT_FRONT2_ID (1b)"

log_info "Aguardando Mount Targets ficarem disponíveis..."
# Poll manual — o wait nativo do EFS para mount targets pode não estar em todas as versões da CLI
for i in $(seq 1 24); do
  STATE_1=$(aws efs describe-mount-targets \
    --mount-target-id "$MT_FRONT1_ID" \
    --query 'MountTargets[0].LifeCycleState' --output text)
  STATE_2=$(aws efs describe-mount-targets \
    --mount-target-id "$MT_FRONT2_ID" \
    --query 'MountTargets[0].LifeCycleState' --output text)
  if [[ "$STATE_1" == "available" && "$STATE_2" == "available" ]]; then
    break
  fi
  log_info "  Mount Targets: $STATE_1 / $STATE_2 — aguardando 10s... ($i/24)"
  sleep 10
done

log_ok "Mount Targets disponíveis"

# ================================================================
#  8. INSTÂNCIAS EC2
# ================================================================

log_section "8/11 — Criando Instâncias EC2"

# O EFS_DNS_NAME é construído conforme o padrão da AWS
EFS_DNS_NAME="${EFS_ID}.efs.${AWS_REGION}.amazonaws.com"

FRONTEND_USER_DATA=$(cat <<USERDATA
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y nginx nfs-common stunnel4

# Aguarda o DNS do EFS propagar (mount target pode demorar a resolver)
EFS_DNS="${EFS_DNS_NAME}"
echo "Aguardando DNS do EFS resolver..." >> /var/log/deploy.log
for i in \$(seq 1 30); do
  if host "\$EFS_DNS" > /dev/null 2>&1; then
    echo "DNS do EFS resolvido na tentativa \$i" >> /var/log/deploy.log
    break
  fi
  sleep 10
done

# Monta o EFS em /var/www/html (conteúdo compartilhado entre os frontends)
mkdir -p /var/www/html
echo "\${EFS_DNS}:/ /var/www/html nfs4 nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,_netdev 0 0" >> /etc/fstab

# Tenta montar com retry
for i in \$(seq 1 10); do
  if mount -a 2>/dev/null && mountpoint -q /var/www/html; then
    echo "EFS montado com sucesso na tentativa \$i" >> /var/log/deploy.log
    break
  fi
  echo "Tentativa \$i de montar EFS falhou, aguardando 15s..." >> /var/log/deploy.log
  sleep 15
done

if ! mountpoint -q /var/www/html; then
  echo "ERRO: EFS nao montou apos 10 tentativas" >> /var/log/deploy.log
  exit 1
fi

# Nginx aponta para /var/www/html
cat > /etc/nginx/sites-available/app.conf <<'NGINX'
server {
    listen 80 default_server;
    server_name _;
    root /var/www/html;
    index index.html index.htm;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
NGINX

rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/app.conf /etc/nginx/sites-enabled/app.conf

# Página placeholder — será substituída pelo conteúdo real no EFS
if [ ! -f /var/www/html/index.html ]; then
  cat > /var/www/html/index.html <<HTML
<!DOCTYPE html>
<html>
<head><title>Frontend - Minha App</title></head>
<body>
  <h1>Frontend funcionando!</h1>
  <p>Conteudo servido via EFS — implante os arquivos em /var/www/html.</p>
</body>
</html>
HTML
fi

systemctl enable nginx
systemctl restart nginx
echo "Frontend configurado com sucesso" >> /var/log/deploy.log
USERDATA
)

BACKEND_USER_DATA=$(cat <<'USERDATA'
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y openjdk-17-jdk maven
mkdir -p /opt/app
chown ubuntu:ubuntu /opt/app
echo "Backend (Java/Spring) configurado" >> /var/log/deploy.log
java -version >> /var/log/deploy.log 2>&1
USERDATA
)

log_info "Iniciando instâncias..."

# ── Frontend 1a ───────────────────────────────────────────────
INSTANCE_FRONTEND_1_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type "$INSTANCE_TYPE_FRONTEND" \
  --subnet-id "$SUBNET_PRIVATE_FRONT1_ID" \
  --security-group-ids "$SG_FRONTEND_ID" \
  --key-name "$KEY_PAIR_NAME" \
  --user-data "$FRONTEND_USER_DATA" \
  --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":30,"VolumeType":"gp3","DeleteOnTermination":true}}]' \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${PROJECT_NAME}-frontend-1a},{Key=Project,Value=${PROJECT_NAME}},{Key=Layer,Value=frontend}]" \
  --query 'Instances[0].InstanceId' \
  --output text)

# ── Frontend 1b ───────────────────────────────────────────────
INSTANCE_FRONTEND_2_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type "$INSTANCE_TYPE_FRONTEND" \
  --subnet-id "$SUBNET_PRIVATE_FRONT2_ID" \
  --security-group-ids "$SG_FRONTEND_ID" \
  --key-name "$KEY_PAIR_NAME" \
  --user-data "$FRONTEND_USER_DATA" \
  --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":30,"VolumeType":"gp3","DeleteOnTermination":true}}]' \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${PROJECT_NAME}-frontend-2b},{Key=Project,Value=${PROJECT_NAME}},{Key=Layer,Value=frontend}]" \
  --query 'Instances[0].InstanceId' \
  --output text)

# ── Backend 1a (par do Frontend 1a) ──────────────────────────
INSTANCE_BACKEND_1_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type "$INSTANCE_TYPE_BACKEND" \
  --subnet-id "$SUBNET_PRIVATE_BACKEND1_ID" \
  --security-group-ids "$SG_BACKEND_ID" \
  --key-name "$KEY_PAIR_NAME" \
  --user-data "$BACKEND_USER_DATA" \
  --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":30,"VolumeType":"gp3","DeleteOnTermination":true}}]' \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${PROJECT_NAME}-backend-1a},{Key=Project,Value=${PROJECT_NAME}},{Key=Layer,Value=backend}]" \
  --query 'Instances[0].InstanceId' \
  --output text)

# ── Backend 1b (par do Frontend 1b) ──────────────────────────
INSTANCE_BACKEND_2_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type "$INSTANCE_TYPE_BACKEND" \
  --subnet-id "$SUBNET_PRIVATE_BACKEND2_ID" \
  --security-group-ids "$SG_BACKEND_ID" \
  --key-name "$KEY_PAIR_NAME" \
  --user-data "$BACKEND_USER_DATA" \
  --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":30,"VolumeType":"gp3","DeleteOnTermination":true}}]' \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${PROJECT_NAME}-backend-1b},{Key=Project,Value=${PROJECT_NAME}},{Key=Layer,Value=backend}]" \
  --query 'Instances[0].InstanceId' \
  --output text)

# ── Bastion Host ──────────────────────────────────────────────
INSTANCE_BASTION_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type "$INSTANCE_TYPE_BASTION" \
  --subnet-id "$SUBNET_PUBLIC_1_ID" \
  --security-group-ids "$SG_BASTION_ID" \
  --key-name "$KEY_PAIR_NAME" \
  --associate-public-ip-address \
  --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":30,"VolumeType":"gp3","DeleteOnTermination":true}}]' \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${PROJECT_NAME}-bastion},{Key=Project,Value=${PROJECT_NAME}},{Key=Layer,Value=bastion}]" \
  --query 'Instances[0].InstanceId' \
  --output text)

log_info "Aguardando todas as instâncias ficarem 'running'..."
aws ec2 wait instance-running \
  --instance-ids "$INSTANCE_FRONTEND_1_ID" "$INSTANCE_FRONTEND_2_ID" \
                 "$INSTANCE_BACKEND_1_ID" "$INSTANCE_BACKEND_2_ID" \
                 "$INSTANCE_BASTION_ID" \
  --region "$AWS_REGION"

log_ok "Frontend 1a:   $INSTANCE_FRONTEND_1_ID"
log_ok "Frontend 1b:   $INSTANCE_FRONTEND_2_ID"
log_ok "Backend 1a:    $INSTANCE_BACKEND_1_ID"
log_ok "Backend 1b:    $INSTANCE_BACKEND_2_ID"
log_ok "Bastion Host:  $INSTANCE_BASTION_ID"

# ================================================================
#  9. RDS MYSQL (Multi-AZ opcional)
# ================================================================

log_section "9/11 — Criando RDS MySQL (banco: ${DB_NAME})"

# Subnet Group para o RDS (requer ao menos 2 AZs)
RDS_SUBNET_GROUP_NAME="${PROJECT_NAME}-rds-subnet-group"

aws rds create-db-subnet-group \
  --db-subnet-group-name "$RDS_SUBNET_GROUP_NAME" \
  --db-subnet-group-description "Subnet group para RDS ${PROJECT_NAME}" \
  --subnet-ids "$SUBNET_PRIVATE_DB1_ID" "$SUBNET_PRIVATE_DB2_ID" \
  --tags "Key=Name,Value=${RDS_SUBNET_GROUP_NAME}" "Key=Project,Value=${PROJECT_NAME}" > /dev/null

log_ok "RDS Subnet Group criado: $RDS_SUBNET_GROUP_NAME"

RDS_IDENTIFIER="${PROJECT_NAME}-mysql"

aws rds create-db-instance \
  --db-instance-identifier "$RDS_IDENTIFIER" \
  --db-instance-class "$DB_INSTANCE_CLASS" \
  --engine mysql \
  --engine-version "8.0" \
  --master-username "$DB_MASTER_USER" \
  --master-user-password "$DB_MASTER_PASSWORD" \
  --db-name "$DB_NAME" \
  --allocated-storage 20 \
  --max-allocated-storage 100 \
  --storage-type gp3 \
  --storage-encrypted \
  --vpc-security-group-ids "$SG_RDS_ID" \
  --db-subnet-group-name "$RDS_SUBNET_GROUP_NAME" \
  --no-multi-az \
  --no-publicly-accessible \
  --backup-retention-period 7 \
  --preferred-backup-window "02:00-03:00" \
  --preferred-maintenance-window "sun:04:00-sun:05:00" \
  --deletion-protection \
  --tags "Key=Name,Value=${RDS_IDENTIFIER}" "Key=Project,Value=${PROJECT_NAME}" > /dev/null

# O RDS leva ~5-10 min — não bloqueamos o script aqui, informamos ao final
log_ok "RDS iniciando em background: $RDS_IDENTIFIER (banco: ${DB_NAME})"
log_warn "O RDS leva ~5-10 minutos para ficar disponível. Acompanhe com:"
log_warn "  aws rds describe-db-instances --db-instance-identifier ${RDS_IDENTIFIER} --query 'DBInstances[0].DBInstanceStatus'"

# ================================================================
#  10. TARGET GROUP + ALB
# ================================================================

log_section "10/11 — Criando Target Group e Application Load Balancer"

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
#  11. INFORMAÇÕES FINAIS
# ================================================================

log_section "11/11 — Coletando informações finais"

IP_FRONTEND_1=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_FRONTEND_1_ID" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' \
  --output text)

IP_FRONTEND_2=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_FRONTEND_2_ID" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' \
  --output text)

IP_BACKEND_1=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_BACKEND_1_ID" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' \
  --output text)

IP_BACKEND_2=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_BACKEND_2_ID" \
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

# Endpoint do RDS (pode ainda estar criando — mostramos o padrão esperado)
RDS_ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier "$RDS_IDENTIFIER" \
  --query 'DBInstances[0].Endpoint.Address' \
  --output text 2>/dev/null || echo "(ainda provisionando — verifique em alguns minutos)")

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
echo    "  ├─ Pública NAT+Bastion (1a):  $SUBNET_PUBLIC_1_ID   (10.0.0.0/26)"
echo    "  ├─ Pública ALB (1b):          $SUBNET_PUBLIC_2_ID   (10.0.0.64/26)"
echo    "  ├─ Privada Frontend-1a:       $SUBNET_PRIVATE_FRONT1_ID   (10.0.0.128/28)"
echo    "  ├─ Privada Frontend-1b:       $SUBNET_PRIVATE_FRONT2_ID   (10.0.0.144/28)"
echo    "  ├─ Privada Backend-1a:        $SUBNET_PRIVATE_BACKEND1_ID (10.0.0.160/28)"
echo    "  ├─ Privada Backend-1b:        $SUBNET_PRIVATE_BACKEND2_ID (10.0.0.176/28)"
echo    "  ├─ Privada RDS-1a:            $SUBNET_PRIVATE_DB1_ID      (10.0.0.192/28)"
echo    "  └─ Privada RDS-1b:            $SUBNET_PRIVATE_DB2_ID      (10.0.0.208/28)"
echo ""
echo -e "${BLUE}  EFS${NC}"
echo    "  ├─ File System ID:   $EFS_ID"
echo    "  ├─ DNS Name:         $EFS_DNS_NAME"
echo    "  ├─ Mount Target 1a:  $MT_FRONT1_ID"
echo    "  └─ Mount Target 1b:  $MT_FRONT2_ID"
echo    "  (montado em /var/www/html em ambas as instâncias Frontend)"
echo ""
echo -e "${BLUE}  INSTÂNCIAS EC2${NC}"
echo    "  ├─ Bastion    [pub: $IP_BASTION_PUBLIC | priv: $IP_BASTION_PRIVATE]:  $INSTANCE_BASTION_ID"
echo    "  ├─ Frontend 1a [$IP_FRONTEND_1]:  $INSTANCE_FRONTEND_1_ID"
echo    "  ├─ Frontend 1b [$IP_FRONTEND_2]:  $INSTANCE_FRONTEND_2_ID"
echo    "  ├─ Backend 1a  [$IP_BACKEND_1]:   $INSTANCE_BACKEND_1_ID"
echo    "  └─ Backend 1b  [$IP_BACKEND_2]:   $INSTANCE_BACKEND_2_ID"
echo ""
echo -e "${BLUE}  RDS MYSQL${NC}"
echo    "  ├─ Identificador: $RDS_IDENTIFIER"
echo    "  ├─ Banco:         $DB_NAME"
echo    "  ├─ Usuário:       $DB_MASTER_USER"
echo    "  └─ Endpoint:      $RDS_ENDPOINT"
echo ""
echo -e "${BLUE}  LOAD BALANCER${NC}"
echo    "  └─ DNS: $ALB_DNS"
echo ""
echo -e "${YELLOW}  ▶  Aplicação: http://$ALB_DNS${NC}"
echo ""
echo -e "${GREEN}  ── COMO ACESSAR VIA SSH ──────────────────────────────${NC}"
echo ""
echo    "  Opção A — SSH Agent Forwarding (recomendado):"
echo    "    ssh -A -i ~/.ssh/${KEY_PAIR_NAME}.pem ubuntu@${IP_BASTION_PUBLIC}  # entra no Bastion"
echo    "    ssh ubuntu@${IP_FRONTEND_1}   # Frontend 1a  (a partir do Bastion)"
echo    "    ssh ubuntu@${IP_FRONTEND_2}   # Frontend 1b  (a partir do Bastion)"
echo    "    ssh ubuntu@${IP_BACKEND_1}    # Backend 1a   (a partir do Bastion)"
echo    "    ssh ubuntu@${IP_BACKEND_2}    # Backend 1b   (a partir do Bastion)"
echo ""
echo    "  Opção B — ProxyJump (direto do seu PC):"
echo    "    ssh -J ubuntu@${IP_BASTION_PUBLIC} -i ~/.ssh/${KEY_PAIR_NAME}.pem ubuntu@${IP_FRONTEND_1}"
echo    "    ssh -J ubuntu@${IP_BASTION_PUBLIC} -i ~/.ssh/${KEY_PAIR_NAME}.pem ubuntu@${IP_FRONTEND_2}"
echo    "    ssh -J ubuntu@${IP_BASTION_PUBLIC} -i ~/.ssh/${KEY_PAIR_NAME}.pem ubuntu@${IP_BACKEND_1}"
echo    "    ssh -J ubuntu@${IP_BASTION_PUBLIC} -i ~/.ssh/${KEY_PAIR_NAME}.pem ubuntu@${IP_BACKEND_2}"
echo ""
echo -e "${YELLOW}  ⚠  ATENÇÃO:${NC}"
echo    "  • Aguarde ~3-5 minutos para o user-data finalizar nas instâncias EC2."
echo    "  • O RDS leva ~5-10 minutos adicionais para ficar disponível."
echo    "  • Altere DB_MASTER_PASSWORD antes de ir para produção!"
echo    "  • Para maior segurança, defina BASTION_SSH_CIDR com seu IP fixo."
echo    "  • Considere habilitar Multi-AZ no RDS (--multi-az) para produção."
echo    "  • Considere HTTPS no ALB via AWS Certificate Manager."
echo    "  • Conteúdo do frontend: copie os arquivos para /var/www/html em qualquer"
echo    "    instância Frontend — o EFS replica automaticamente para ambas."
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
SUBNET_PRIVATE_BACKEND1=$SUBNET_PRIVATE_BACKEND1_ID
SUBNET_PRIVATE_BACKEND2=$SUBNET_PRIVATE_BACKEND2_ID
SUBNET_PRIVATE_DB1=$SUBNET_PRIVATE_DB1_ID
SUBNET_PRIVATE_DB2=$SUBNET_PRIVATE_DB2_ID

SG_BASTION=$SG_BASTION_ID
SG_ALB=$SG_ALB_ID
SG_FRONTEND=$SG_FRONTEND_ID
SG_EFS=$SG_EFS_ID
SG_BACKEND=$SG_BACKEND_ID
SG_RDS=$SG_RDS_ID

EFS_ID=$EFS_ID
EFS_DNS=$EFS_DNS_NAME
EFS_MOUNT_TARGET_1A=$MT_FRONT1_ID
EFS_MOUNT_TARGET_1B=$MT_FRONT2_ID

INSTANCE_BASTION=$INSTANCE_BASTION_ID  (pub=$IP_BASTION_PUBLIC | priv=$IP_BASTION_PRIVATE)
INSTANCE_FRONTEND_1A=$INSTANCE_FRONTEND_1_ID ($IP_FRONTEND_1)
INSTANCE_FRONTEND_1B=$INSTANCE_FRONTEND_2_ID ($IP_FRONTEND_2)
INSTANCE_BACKEND_1A=$INSTANCE_BACKEND_1_ID ($IP_BACKEND_1)
INSTANCE_BACKEND_1B=$INSTANCE_BACKEND_2_ID ($IP_BACKEND_2)

RDS_IDENTIFIER=$RDS_IDENTIFIER
RDS_DB_NAME=$DB_NAME
RDS_USER=$DB_MASTER_USER
RDS_ENDPOINT=$RDS_ENDPOINT

ALB_ARN=$ALB_ARN
ALB_DNS=$ALB_DNS
TG_ARN=$TG_ARN

URL=http://$ALB_DNS

# SSH — Agent Forwarding
SSH_BASTION=ssh -A -i ~/.ssh/${KEY_PAIR_NAME}.pem ubuntu@${IP_BASTION_PUBLIC}
SSH_FRONTEND_1A=ssh ubuntu@${IP_FRONTEND_1}
SSH_FRONTEND_1B=ssh ubuntu@${IP_FRONTEND_2}
SSH_BACKEND_1A=ssh ubuntu@${IP_BACKEND_1}
SSH_BACKEND_1B=ssh ubuntu@${IP_BACKEND_2}

# SSH — ProxyJump (direto do seu PC)
JUMP_FRONTEND_1A=ssh -J ubuntu@${IP_BASTION_PUBLIC} -i ~/.ssh/${KEY_PAIR_NAME}.pem ubuntu@${IP_FRONTEND_1}
JUMP_FRONTEND_1B=ssh -J ubuntu@${IP_BASTION_PUBLIC} -i ~/.ssh/${KEY_PAIR_NAME}.pem ubuntu@${IP_FRONTEND_2}
JUMP_BACKEND_1A=ssh -J ubuntu@${IP_BASTION_PUBLIC} -i ~/.ssh/${KEY_PAIR_NAME}.pem ubuntu@${IP_BACKEND_1}
JUMP_BACKEND_1B=ssh -J ubuntu@${IP_BASTION_PUBLIC} -i ~/.ssh/${KEY_PAIR_NAME}.pem ubuntu@${IP_BACKEND_2}
SUMMARY

log_ok "Resumo e comandos SSH salvos em: $SUMMARY_FILE"
echo ""