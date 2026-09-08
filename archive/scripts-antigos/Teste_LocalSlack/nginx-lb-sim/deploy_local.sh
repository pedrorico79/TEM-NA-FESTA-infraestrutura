#!/bin/bash

set -uo pipefail   

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC}  $1" >&2; }
log_ok()      { echo -e "${GREEN}[OK]${NC}    $1" >&2; }
log_warn()    { echo -e "${YELLOW}[AVISO]${NC} $1" >&2; }
log_error()   { echo -e "${RED}[ERRO]${NC}  $1" >&2; exit 1; }
log_section() { echo -e "\n${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" >&2; echo -e "${YELLOW}  $1${NC}" >&2; echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" >&2; }

run_soft() {
  local desc="$1"; shift
  if ! OUT=$("$@" 2>&1); then
    log_warn "$desc falhou (provavelmente falta de entitlement no LocalStack). Detalhe:"
    echo "$OUT" | sed 's/^/    /' >&2
    return 1
  fi
  echo "$OUT"
  return 0
}

# ================================================================
#  CONFIGURAÇÕES
# ================================================================

ENDPOINT="http://localhost:4566"
AWS_REGION="us-east-1"
PROJECT_NAME="minha-infra-local"

INSTANCE_TYPE_FRONTEND="t3.micro"
INSTANCE_TYPE_BACKEND="t3.small"
INSTANCE_TYPE_DB="t3.small"
INSTANCE_TYPE_BASTION="t3.micro"

# AMI falso — o LocalStack mock não valida contra AMIs reais
AMI_ID="ami-0123456789abcdef0"

BACKEND_PORT=8080
BASTION_SSH_CIDR="0.0.0.0/0"

# ================================================================
#  0. SUBIR LOCALSTACK E ESPERAR FICAR PRONTO
# ================================================================

log_section "0/9 — Subindo LocalStack"

if [ -z "${LOCALSTACK_AUTH_TOKEN:-}" ]; then
    log_warn "LOCALSTACK_AUTH_TOKEN não definido no ambiente."
    log_warn "Exporte antes de continuar: export LOCALSTACK_AUTH_TOKEN=seu_token"
    log_warn "Sem token, o container pode subir mas recusar chamadas de API."
fi

# Credenciais falsas exigidas pela AWS CLI (valor não importa p/ LocalStack)
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_DEFAULT_REGION="$AWS_REGION"

docker compose up -d || docker-compose up -d

log_info "Aguardando LocalStack responder no healthcheck..."
TRIES=0
until curl -sf "${ENDPOINT}/_localstack/health" > /dev/null 2>&1; do
    TRIES=$((TRIES+1))
    if [ "$TRIES" -gt 30 ]; then
        log_error "LocalStack não respondeu após 60s. Verifique 'docker compose logs localstack'."
    fi
    sleep 2
done
log_ok "LocalStack pronto em $ENDPOINT"

AWSL() { aws --endpoint-url="$ENDPOINT" --region "$AWS_REGION" "$@"; }

# ================================================================
#  1. VPC
# ================================================================

log_section "1/9 — Criando VPC (10.0.0.0/24)"

VPC_ID=$(run_soft "create-vpc" AWSL ec2 create-vpc \
  --cidr-block "10.0.0.0/24" \
  --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=${PROJECT_NAME}-vpc}]" \
  --query 'Vpc.VpcId' --output text) || VPC_ID=""

if [ -n "$VPC_ID" ]; then
    AWSL ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames "{\"Value\":true}" > /dev/null 2>&1 || true
    AWSL ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support "{\"Value\":true}" > /dev/null 2>&1 || true
    log_ok "VPC criada: $VPC_ID"
else
    log_error "Não foi possível criar a VPC — sem EC2/entitlement, o restante do script não tem como continuar. Veja a seção 'Realista' se quiser um script sem VPC/EC2."
fi

# ================================================================
#  2. INTERNET GATEWAY
# ================================================================

log_section "2/9 — Criando Internet Gateway"

IGW_ID=$(run_soft "create-internet-gateway" AWSL ec2 create-internet-gateway \
  --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=${PROJECT_NAME}-igw}]" \
  --query 'InternetGateway.InternetGatewayId' --output text) || IGW_ID=""

if [ -n "$IGW_ID" ]; then
    AWSL ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" > /dev/null 2>&1 || true
    log_ok "IGW criado e anexado: $IGW_ID"
else
    log_warn "IGW não criado — seguindo sem ele."
fi

# ================================================================
#  3. SUB-REDES
# ================================================================

log_section "3/9 — Criando Sub-redes"

SUBNET_PUBLIC_1_ID=$(run_soft "subnet pública 1a" AWSL ec2 create-subnet \
  --vpc-id "$VPC_ID" --cidr-block "10.0.0.0/26" --availability-zone "${AWS_REGION}a" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${PROJECT_NAME}-public-nat-bastion-1a}]" \
  --query 'Subnet.SubnetId' --output text) || SUBNET_PUBLIC_1_ID=""

SUBNET_PUBLIC_2_ID=$(run_soft "subnet pública 1b" AWSL ec2 create-subnet \
  --vpc-id "$VPC_ID" --cidr-block "10.0.0.64/26" --availability-zone "${AWS_REGION}b" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${PROJECT_NAME}-public-alb-1b}]" \
  --query 'Subnet.SubnetId' --output text) || SUBNET_PUBLIC_2_ID=""

[ -n "$SUBNET_PUBLIC_1_ID" ] && AWSL ec2 modify-subnet-attribute --subnet-id "$SUBNET_PUBLIC_1_ID" --map-public-ip-on-launch > /dev/null 2>&1 || true
[ -n "$SUBNET_PUBLIC_2_ID" ] && AWSL ec2 modify-subnet-attribute --subnet-id "$SUBNET_PUBLIC_2_ID" --map-public-ip-on-launch > /dev/null 2>&1 || true

log_ok "Públicas: ${SUBNET_PUBLIC_1_ID:-<falhou>} (1a) | ${SUBNET_PUBLIC_2_ID:-<falhou>} (1b)"

SUBNET_PRIVATE_FRONT1_ID=$(run_soft "subnet privada frontend-1a" AWSL ec2 create-subnet \
  --vpc-id "$VPC_ID" --cidr-block "10.0.0.128/27" --availability-zone "${AWS_REGION}a" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${PROJECT_NAME}-private-frontend-1a}]" \
  --query 'Subnet.SubnetId' --output text) || SUBNET_PRIVATE_FRONT1_ID=""

SUBNET_PRIVATE_FRONT2_ID=$(run_soft "subnet privada frontend-1b" AWSL ec2 create-subnet \
  --vpc-id "$VPC_ID" --cidr-block "10.0.0.160/27" --availability-zone "${AWS_REGION}b" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${PROJECT_NAME}-private-frontend-1b}]" \
  --query 'Subnet.SubnetId' --output text) || SUBNET_PRIVATE_FRONT2_ID=""

SUBNET_PRIVATE_BACKEND_ID=$(run_soft "subnet privada backend" AWSL ec2 create-subnet \
  --vpc-id "$VPC_ID" --cidr-block "10.0.0.192/27" --availability-zone "${AWS_REGION}a" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${PROJECT_NAME}-private-backend-1a}]" \
  --query 'Subnet.SubnetId' --output text) || SUBNET_PRIVATE_BACKEND_ID=""

SUBNET_PRIVATE_DB_ID=$(run_soft "subnet privada db" AWSL ec2 create-subnet \
  --vpc-id "$VPC_ID" --cidr-block "10.0.0.224/27" --availability-zone "${AWS_REGION}a" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${PROJECT_NAME}-private-db-1a}]" \
  --query 'Subnet.SubnetId' --output text) || SUBNET_PRIVATE_DB_ID=""

log_ok "Frontend-1: ${SUBNET_PRIVATE_FRONT1_ID:-<falhou>} | Frontend-2: ${SUBNET_PRIVATE_FRONT2_ID:-<falhou>}"
log_ok "Backend:    ${SUBNET_PRIVATE_BACKEND_ID:-<falhou>} | DB: ${SUBNET_PRIVATE_DB_ID:-<falhou>}"

# ================================================================
#  4. NAT GATEWAY + ELASTIC IP
# ================================================================

log_section "4/9 — Criando NAT Gateway (com Elastic IP)"
log_warn "Emulação de NAT Gateway no LocalStack tem bug conhecido de IP fora do CIDR — trate como best-effort."

NAT_GW_ID=""
if [ -n "$SUBNET_PUBLIC_1_ID" ]; then
    EIP_ALLOC_ID=$(run_soft "allocate-address" AWSL ec2 allocate-address \
      --domain vpc --query 'AllocationId' --output text) || EIP_ALLOC_ID=""

    if [ -n "$EIP_ALLOC_ID" ]; then
        NAT_GW_ID=$(run_soft "create-nat-gateway" AWSL ec2 create-nat-gateway \
          --subnet-id "$SUBNET_PUBLIC_1_ID" \
          --allocation-id "$EIP_ALLOC_ID" \
          --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=${PROJECT_NAME}-nat-gw}]" \
          --query 'NatGateway.NatGatewayId' --output text) || NAT_GW_ID=""
    fi
fi

if [ -n "$NAT_GW_ID" ]; then
    log_info "Tentando aguardar NAT Gateway disponível (timeout 30s)..."
    timeout 30 aws --endpoint-url="$ENDPOINT" --region "$AWS_REGION" ec2 wait nat-gateway-available \
      --nat-gateway-ids "$NAT_GW_ID" 2>/dev/null \
      && log_ok "NAT Gateway disponível: $NAT_GW_ID" \
      || log_warn "Wait expirou/falhou — seguindo mesmo assim (NAT_GW_ID=$NAT_GW_ID)."
else
    log_warn "NAT Gateway não criado — rotas privadas ficarão sem saída simulada."
fi

# ================================================================
#  5. ROUTE TABLES
# ================================================================

log_section "5/9 — Configurando Tabelas de Roteamento"

RT_PUBLIC_ID=$(run_soft "route table pública" AWSL ec2 create-route-table \
  --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${PROJECT_NAME}-rt-public}]" \
  --query 'RouteTable.RouteTableId' --output text) || RT_PUBLIC_ID=""

if [ -n "$RT_PUBLIC_ID" ] && [ -n "$IGW_ID" ]; then
    AWSL ec2 create-route --route-table-id "$RT_PUBLIC_ID" \
      --destination-cidr-block "0.0.0.0/0" --gateway-id "$IGW_ID" > /dev/null 2>&1 || log_warn "create-route (público) falhou"
    [ -n "$SUBNET_PUBLIC_1_ID" ] && AWSL ec2 associate-route-table --route-table-id "$RT_PUBLIC_ID" --subnet-id "$SUBNET_PUBLIC_1_ID" > /dev/null 2>&1
    [ -n "$SUBNET_PUBLIC_2_ID" ] && AWSL ec2 associate-route-table --route-table-id "$RT_PUBLIC_ID" --subnet-id "$SUBNET_PUBLIC_2_ID" > /dev/null 2>&1
    log_ok "Route Table Pública: $RT_PUBLIC_ID → IGW"
fi

RT_PRIVATE_ID=$(run_soft "route table privada" AWSL ec2 create-route-table \
  --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${PROJECT_NAME}-rt-private}]" \
  --query 'RouteTable.RouteTableId' --output text) || RT_PRIVATE_ID=""

if [ -n "$RT_PRIVATE_ID" ] && [ -n "$NAT_GW_ID" ]; then
    AWSL ec2 create-route --route-table-id "$RT_PRIVATE_ID" \
      --destination-cidr-block "0.0.0.0/0" --nat-gateway-id "$NAT_GW_ID" > /dev/null 2>&1 || log_warn "create-route (privado) falhou"
fi
[ -n "$RT_PRIVATE_ID" ] && [ -n "$SUBNET_PRIVATE_FRONT1_ID" ]  && AWSL ec2 associate-route-table --route-table-id "$RT_PRIVATE_ID" --subnet-id "$SUBNET_PRIVATE_FRONT1_ID"  > /dev/null 2>&1
[ -n "$RT_PRIVATE_ID" ] && [ -n "$SUBNET_PRIVATE_FRONT2_ID" ]  && AWSL ec2 associate-route-table --route-table-id "$RT_PRIVATE_ID" --subnet-id "$SUBNET_PRIVATE_FRONT2_ID"  > /dev/null 2>&1
[ -n "$RT_PRIVATE_ID" ] && [ -n "$SUBNET_PRIVATE_BACKEND_ID" ] && AWSL ec2 associate-route-table --route-table-id "$RT_PRIVATE_ID" --subnet-id "$SUBNET_PRIVATE_BACKEND_ID" > /dev/null 2>&1
[ -n "$RT_PRIVATE_ID" ] && [ -n "$SUBNET_PRIVATE_DB_ID" ]      && AWSL ec2 associate-route-table --route-table-id "$RT_PRIVATE_ID" --subnet-id "$SUBNET_PRIVATE_DB_ID"      > /dev/null 2>&1

log_ok "Route Table Privada: ${RT_PRIVATE_ID:-<falhou>} → NAT Gateway"

# ================================================================
#  6. SECURITY GROUPS
# ================================================================

log_section "6/9 — Criando Security Groups"

SG_BASTION_ID=$(run_soft "sg bastion" AWSL ec2 create-security-group \
  --group-name "${PROJECT_NAME}-sg-bastion" --description "Bastion SSH externo" --vpc-id "$VPC_ID" \
  --query 'GroupId' --output text) || SG_BASTION_ID=""
[ -n "$SG_BASTION_ID" ] && AWSL ec2 authorize-security-group-ingress --group-id "$SG_BASTION_ID" \
  --protocol tcp --port 22 --cidr "$BASTION_SSH_CIDR" > /dev/null 2>&1
log_ok "SG Bastion: ${SG_BASTION_ID:-<falhou>}"

SG_ALB_ID=$(run_soft "sg alb" AWSL ec2 create-security-group \
  --group-name "${PROJECT_NAME}-sg-alb" --description "ALB HTTP/HTTPS publico" --vpc-id "$VPC_ID" \
  --query 'GroupId' --output text) || SG_ALB_ID=""
if [ -n "$SG_ALB_ID" ]; then
    AWSL ec2 authorize-security-group-ingress --group-id "$SG_ALB_ID" --protocol tcp --port 80 --cidr 0.0.0.0/0 > /dev/null 2>&1
    AWSL ec2 authorize-security-group-ingress --group-id "$SG_ALB_ID" --protocol tcp --port 443 --cidr 0.0.0.0/0 > /dev/null 2>&1
fi
log_ok "SG ALB: ${SG_ALB_ID:-<falhou>}"

SG_FRONTEND_ID=$(run_soft "sg frontend" AWSL ec2 create-security-group \
  --group-name "${PROJECT_NAME}-sg-frontend" --description "Frontend HTTP do ALB e SSH do Bastion" --vpc-id "$VPC_ID" \
  --query 'GroupId' --output text) || SG_FRONTEND_ID=""
if [ -n "$SG_FRONTEND_ID" ]; then
    [ -n "$SG_ALB_ID" ] && AWSL ec2 authorize-security-group-ingress --group-id "$SG_FRONTEND_ID" \
      --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":80,\"ToPort\":80,\"UserIdGroupPairs\":[{\"GroupId\":\"$SG_ALB_ID\"}]}]" > /dev/null 2>&1
    [ -n "$SG_BASTION_ID" ] && AWSL ec2 authorize-security-group-ingress --group-id "$SG_FRONTEND_ID" \
      --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":22,\"ToPort\":22,\"UserIdGroupPairs\":[{\"GroupId\":\"$SG_BASTION_ID\"}]}]" > /dev/null 2>&1
fi
log_ok "SG Frontend: ${SG_FRONTEND_ID:-<falhou>}"

SG_BACKEND_ID=$(run_soft "sg backend" AWSL ec2 create-security-group \
  --group-name "${PROJECT_NAME}-sg-backend" --description "Backend porta app do Frontend e SSH do Bastion" --vpc-id "$VPC_ID" \
  --query 'GroupId' --output text) || SG_BACKEND_ID=""
if [ -n "$SG_BACKEND_ID" ]; then
    [ -n "$SG_FRONTEND_ID" ] && AWSL ec2 authorize-security-group-ingress --group-id "$SG_BACKEND_ID" \
      --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":${BACKEND_PORT},\"ToPort\":${BACKEND_PORT},\"UserIdGroupPairs\":[{\"GroupId\":\"$SG_FRONTEND_ID\"}]}]" > /dev/null 2>&1
    [ -n "$SG_BASTION_ID" ] && AWSL ec2 authorize-security-group-ingress --group-id "$SG_BACKEND_ID" \
      --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":22,\"ToPort\":22,\"UserIdGroupPairs\":[{\"GroupId\":\"$SG_BASTION_ID\"}]}]" > /dev/null 2>&1
fi
log_ok "SG Backend: ${SG_BACKEND_ID:-<falhou>}"

SG_DB_ID=$(run_soft "sg db" AWSL ec2 create-security-group \
  --group-name "${PROJECT_NAME}-sg-db" --description "DB MySQL do Backend e SSH do Bastion" --vpc-id "$VPC_ID" \
  --query 'GroupId' --output text) || SG_DB_ID=""
if [ -n "$SG_DB_ID" ]; then
    [ -n "$SG_BACKEND_ID" ] && AWSL ec2 authorize-security-group-ingress --group-id "$SG_DB_ID" \
      --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":3306,\"ToPort\":3306,\"UserIdGroupPairs\":[{\"GroupId\":\"$SG_BACKEND_ID\"}]}]" > /dev/null 2>&1
    [ -n "$SG_BASTION_ID" ] && AWSL ec2 authorize-security-group-ingress --group-id "$SG_DB_ID" \
      --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":22,\"ToPort\":22,\"UserIdGroupPairs\":[{\"GroupId\":\"$SG_BASTION_ID\"}]}]" > /dev/null 2>&1
fi
log_ok "SG Banco de Dados: ${SG_DB_ID:-<falhou>}"

# ================================================================
#  7. INSTÂNCIAS EC2 (mocks de estado — sem VM real)
# ================================================================

log_section "7/9 — Criando Instâncias EC2 (mock)"
log_warn "Instâncias no LocalStack não executam user-data de verdade; nginx/java/mysql não sobem de fato."

INSTANCE_FRONTEND_1_ID=$(run_soft "run-instances frontend-1" AWSL ec2 run-instances \
  --image-id "$AMI_ID" --instance-type "$INSTANCE_TYPE_FRONTEND" \
  --subnet-id "$SUBNET_PRIVATE_FRONT1_ID" --security-group-ids "$SG_FRONTEND_ID" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${PROJECT_NAME}-frontend-1}]" \
  --query 'Instances[0].InstanceId' --output text) || INSTANCE_FRONTEND_1_ID=""

INSTANCE_FRONTEND_2_ID=$(run_soft "run-instances frontend-2" AWSL ec2 run-instances \
  --image-id "$AMI_ID" --instance-type "$INSTANCE_TYPE_FRONTEND" \
  --subnet-id "$SUBNET_PRIVATE_FRONT2_ID" --security-group-ids "$SG_FRONTEND_ID" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${PROJECT_NAME}-frontend-2}]" \
  --query 'Instances[0].InstanceId' --output text) || INSTANCE_FRONTEND_2_ID=""

INSTANCE_BACKEND_ID=$(run_soft "run-instances backend" AWSL ec2 run-instances \
  --image-id "$AMI_ID" --instance-type "$INSTANCE_TYPE_BACKEND" \
  --subnet-id "$SUBNET_PRIVATE_BACKEND_ID" --security-group-ids "$SG_BACKEND_ID" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${PROJECT_NAME}-backend}]" \
  --query 'Instances[0].InstanceId' --output text) || INSTANCE_BACKEND_ID=""

INSTANCE_DB_ID=$(run_soft "run-instances db" AWSL ec2 run-instances \
  --image-id "$AMI_ID" --instance-type "$INSTANCE_TYPE_DB" \
  --subnet-id "$SUBNET_PRIVATE_DB_ID" --security-group-ids "$SG_DB_ID" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${PROJECT_NAME}-db}]" \
  --query 'Instances[0].InstanceId' --output text) || INSTANCE_DB_ID=""

INSTANCE_BASTION_ID=$(run_soft "run-instances bastion" AWSL ec2 run-instances \
  --image-id "$AMI_ID" --instance-type "$INSTANCE_TYPE_BASTION" \
  --subnet-id "$SUBNET_PUBLIC_1_ID" --security-group-ids "$SG_BASTION_ID" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${PROJECT_NAME}-bastion}]" \
  --query 'Instances[0].InstanceId' --output text) || INSTANCE_BASTION_ID=""

log_ok "Frontend 1: ${INSTANCE_FRONTEND_1_ID:-<falhou>}"
log_ok "Frontend 2: ${INSTANCE_FRONTEND_2_ID:-<falhou>}"
log_ok "Backend:    ${INSTANCE_BACKEND_ID:-<falhou>}"
log_ok "DB:         ${INSTANCE_DB_ID:-<falhou>}"
log_ok "Bastion:    ${INSTANCE_BASTION_ID:-<falhou>}"

# ================================================================
#  8. TARGET GROUP + ALB
# ================================================================

log_section "8/9 — Criando Target Group e ALB"

TG_ARN=""
if [ -n "$VPC_ID" ]; then
    TG_ARN=$(run_soft "create-target-group" AWSL elbv2 create-target-group \
      --name "${PROJECT_NAME}-tg-frontend" --protocol HTTP --port 80 --vpc-id "$VPC_ID" \
      --target-type instance --health-check-protocol HTTP --health-check-path "/" \
      --query 'TargetGroups[0].TargetGroupArn' --output text) || TG_ARN=""
fi

if [ -n "$TG_ARN" ] && [ -n "$INSTANCE_FRONTEND_1_ID" ] && [ -n "$INSTANCE_FRONTEND_2_ID" ]; then
    AWSL elbv2 register-targets --target-group-arn "$TG_ARN" \
      --targets "Id=$INSTANCE_FRONTEND_1_ID,Port=80" "Id=$INSTANCE_FRONTEND_2_ID,Port=80" > /dev/null 2>&1 || log_warn "register-targets falhou"
fi
log_ok "Target Group: ${TG_ARN:-<falhou>}"

ALB_ARN=""
if [ -n "$SUBNET_PUBLIC_1_ID" ] && [ -n "$SUBNET_PUBLIC_2_ID" ] && [ -n "$SG_ALB_ID" ]; then
    ALB_ARN=$(run_soft "create-load-balancer" AWSL elbv2 create-load-balancer \
      --name "${PROJECT_NAME}-alb" \
      --subnets "$SUBNET_PUBLIC_1_ID" "$SUBNET_PUBLIC_2_ID" \
      --security-groups "$SG_ALB_ID" --scheme internet-facing --type application \
      --query 'LoadBalancers[0].LoadBalancerArn' --output text) || ALB_ARN=""
fi

ALB_DNS=""
if [ -n "$ALB_ARN" ] && [ -n "$TG_ARN" ]; then
    AWSL elbv2 create-listener --load-balancer-arn "$ALB_ARN" --protocol HTTP --port 80 \
      --default-actions "Type=forward,TargetGroupArn=$TG_ARN" > /dev/null 2>&1 || log_warn "create-listener falhou"

    log_info "Tentando aguardar ALB ativo (timeout 20s)..."
    timeout 20 aws --endpoint-url="$ENDPOINT" --region "$AWS_REGION" elbv2 wait load-balancer-available \
      --load-balancer-arns "$ALB_ARN" 2>/dev/null || log_warn "Wait do ALB expirou — seguindo mesmo assim."

    ALB_DNS=$(AWSL elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" \
      --query 'LoadBalancers[0].DNSName' --output text 2>/dev/null) || ALB_DNS=""
fi
log_ok "ALB: ${ALB_ARN:-<falhou>} | DNS: ${ALB_DNS:-<indisponível>}"

# ================================================================
#  9. RESUMO
# ================================================================

log_section "9/9 — Resumo"

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   DEPLOY LOCAL (LOCALSTACK) FINALIZADO                ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo "  VPC:                 ${VPC_ID:-<falhou>}"
echo "  IGW:                 ${IGW_ID:-<falhou>}"
echo "  NAT Gateway:         ${NAT_GW_ID:-<falhou>}"
echo "  Subnet pública 1a:   ${SUBNET_PUBLIC_1_ID:-<falhou>}"
echo "  Subnet pública 1b:   ${SUBNET_PUBLIC_2_ID:-<falhou>}"
echo "  Subnet frontend 1a:  ${SUBNET_PRIVATE_FRONT1_ID:-<falhou>}"
echo "  Subnet frontend 1b:  ${SUBNET_PRIVATE_FRONT2_ID:-<falhou>}"
echo "  Subnet backend:      ${SUBNET_PRIVATE_BACKEND_ID:-<falhou>}"
echo "  Subnet db:           ${SUBNET_PRIVATE_DB_ID:-<falhou>}"
echo "  SG bastion/alb/fe/be/db: ${SG_BASTION_ID:-?} / ${SG_ALB_ID:-?} / ${SG_FRONTEND_ID:-?} / ${SG_BACKEND_ID:-?} / ${SG_DB_ID:-?}"
echo "  Instância bastion:   ${INSTANCE_BASTION_ID:-<falhou>}"
echo "  Instância frontend1: ${INSTANCE_FRONTEND_1_ID:-<falhou>}"
echo "  Instância frontend2: ${INSTANCE_FRONTEND_2_ID:-<falhou>}"
echo "  Instância backend:   ${INSTANCE_BACKEND_ID:-<falhou>}"
echo "  Instância db:        ${INSTANCE_DB_ID:-<falhou>}"
echo "  Target Group:        ${TG_ARN:-<falhou>}"
echo "  ALB:                 ${ALB_ARN:-<falhou>}"
echo "  ALB DNS:              ${ALB_DNS:-<indisponível>}"
echo ""

if [ -z "$VPC_ID$IGW_ID$NAT_GW_ID$ALB_ARN" ]; then
    log_warn "Vários recursos falharam. Isso normalmente indica que sua conta LocalStack"
    log_warn "não tem entitlement para EC2/ELBv2 no plano atual. Rode:"
    echo "    aws --endpoint-url=$ENDPOINT ec2 describe-vpcs"
    log_warn "e veja a mensagem de erro completa para confirmar."
fi

SUMMARY_FILE="deploy_summary_local_$(date +%Y%m%d_%H%M%S).txt"
{
  echo "=== RESUMO DO DEPLOY LOCAL - $(date) ==="
  echo "VPC_ID=$VPC_ID"
  echo "IGW_ID=$IGW_ID"
  echo "NAT_GW_ID=$NAT_GW_ID"
  echo "SUBNET_PUBLIC_1=$SUBNET_PUBLIC_1_ID"
  echo "SUBNET_PUBLIC_2=$SUBNET_PUBLIC_2_ID"
  echo "SUBNET_PRIVATE_FRONT1=$SUBNET_PRIVATE_FRONT1_ID"
  echo "SUBNET_PRIVATE_FRONT2=$SUBNET_PRIVATE_FRONT2_ID"
  echo "SUBNET_PRIVATE_BACKEND=$SUBNET_PRIVATE_BACKEND_ID"
  echo "SUBNET_PRIVATE_DB=$SUBNET_PRIVATE_DB_ID"
  echo "SG_BASTION=$SG_BASTION_ID"
  echo "SG_ALB=$SG_ALB_ID"
  echo "SG_FRONTEND=$SG_FRONTEND_ID"
  echo "SG_BACKEND=$SG_BACKEND_ID"
  echo "SG_DB=$SG_DB_ID"
  echo "INSTANCE_BASTION=$INSTANCE_BASTION_ID"
  echo "INSTANCE_FRONTEND_1=$INSTANCE_FRONTEND_1_ID"
  echo "INSTANCE_FRONTEND_2=$INSTANCE_FRONTEND_2_ID"
  echo "INSTANCE_BACKEND=$INSTANCE_BACKEND_ID"
  echo "INSTANCE_DB=$INSTANCE_DB_ID"
  echo "TG_ARN=$TG_ARN"
  echo "ALB_ARN=$ALB_ARN"
  echo "ALB_DNS=$ALB_DNS"
} > "$SUMMARY_FILE"

log_ok "Resumo salvo em: $SUMMARY_FILE"