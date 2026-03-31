#!/bin/bash
# =============================================================================
# destroy-infra-cesarmiguel.sh
# Script completo de destruição de infraestrutura AWS
# Apaga todos os recursos criados pelo setup-infra-cesarmiguel.sh
# =============================================================================
set -e

AWS_REGION="us-east-1"

# Cores para output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${CYAN}[INFO]${NC} $1"; }
ok()   { echo -e "${GREEN}[OK]${NC}   $1"; }
warn() { echo -e "${YELLOW}[WAIT]${NC} $1"; }
err()  { echo -e "${RED}[SKIP]${NC} $1"; }

echo ""
echo "=============================================="
echo "  Destruição de Infraestrutura AWS"
echo "  Projeto: preset-cesarmiguel"
echo "=============================================="
echo ""

# ─── HELPER: busca por tag Name ──────────────────────────────────────────────
get_vpc_id() {
  aws ec2 describe-vpcs \
    --filters "Name=tag:Name,Values=preset-cesarmiguel-vpc" \
    --query 'Vpcs[0].VpcId' --output text --region "$AWS_REGION" 2>/dev/null || echo ""
}

# =============================================================================
# BUSCAR VPC (base para todos os outros recursos)
# =============================================================================
log "Buscando VPC..."
VPC_ID=$(get_vpc_id)

if [ -z "$VPC_ID" ] || [ "$VPC_ID" == "None" ]; then
  echo -e "${RED}VPC não encontrada. Infraestrutura já foi removida ou nunca foi criada.${NC}"
  exit 0
fi
ok "VPC encontrada: $VPC_ID"

# =============================================================================
# PARTE 1 — TERMINAR EC2s
# =============================================================================
echo ""
echo -e "${CYAN}>>> PARTE 1 — Encerrando EC2s${NC}"
echo ""

for TAG in "preset-cesarmiguel-ec2-public-nginx" "preset-cesarmiguel-ec2-private"; do
  INSTANCE_ID=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=$TAG" "Name=instance-state-name,Values=running,stopped,pending" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text --region "$AWS_REGION")

  if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" == "None" ]; then
    err "EC2 '$TAG' não encontrada, pulando..."
  else
    log "Terminando EC2: $INSTANCE_ID ($TAG)..."
    aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$AWS_REGION" > /dev/null
    warn "Aguardando EC2 $INSTANCE_ID ser terminada..."
    aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID" --region "$AWS_REGION"
    ok "EC2 terminada: $INSTANCE_ID"
  fi
done

# =============================================================================
# PARTE 2 — DELETAR SECURITY GROUPS
# =============================================================================
echo ""
echo -e "${CYAN}>>> PARTE 2 — Deletando Security Groups${NC}"
echo ""

for SG_NAME in "preset-cesarmiguel-sg-public" "preset-cesarmiguel-sg-private"; do
  SG_ID=$(aws ec2 describe-security-groups \
    --filters "Name=tag:Name,Values=$SG_NAME" \
    --query 'SecurityGroups[0].GroupId' --output text --region "$AWS_REGION")

  if [ -z "$SG_ID" ] || [ "$SG_ID" == "None" ]; then
    err "SG '$SG_NAME' não encontrado, pulando..."
  else
    log "Deletando Security Group: $SG_ID ($SG_NAME)..."
    aws ec2 delete-security-group --group-id "$SG_ID" --region "$AWS_REGION"
    ok "Security Group deletado: $SG_ID"
  fi
done

# =============================================================================
# PARTE 3 — DELETAR KEY PAIR
# =============================================================================
echo ""
echo -e "${CYAN}>>> PARTE 3 — Deletando Key Pair${NC}"
echo ""

KEY_NAME="preset-cesarmiguel-key"
log "Deletando key pair: $KEY_NAME..."
aws ec2 delete-key-pair --key-name "$KEY_NAME" --region "$AWS_REGION" && ok "Key pair deletado: $KEY_NAME" || err "Key pair não encontrado, pulando..."

# =============================================================================
# PARTE 4 — DELETAR NACLs
# =============================================================================
echo ""
echo -e "${CYAN}>>> PARTE 4 — Deletando NACLs${NC}"
echo ""

for NACL_NAME in "preset-cesarmiguel-nacl-public" "preset-cesarmiguel-nacl-private"; do
  NACL_ID=$(aws ec2 describe-network-acls \
    --filters "Name=tag:Name,Values=$NACL_NAME" \
    --query 'NetworkAcls[0].NetworkAclId' --output text --region "$AWS_REGION")

  if [ -z "$NACL_ID" ] || [ "$NACL_ID" == "None" ]; then
    err "NACL '$NACL_NAME' não encontrada, pulando..."
  else
    log "Deletando NACL: $NACL_ID ($NACL_NAME)..."
    aws ec2 delete-network-acl --network-acl-id "$NACL_ID" --region "$AWS_REGION"
    ok "NACL deletada: $NACL_ID"
  fi
done

# =============================================================================
# PARTE 5 — DELETAR ROUTE TABLES
# =============================================================================
echo ""
echo -e "${CYAN}>>> PARTE 5 — Deletando Route Tables${NC}"
echo ""

for RTB_NAME in "preset-cesarmiguel-rtb-public" "preset-cesarmiguel-rtb-private1-us-east-1a"; do
  RTB_ID=$(aws ec2 describe-route-tables \
    --filters "Name=tag:Name,Values=$RTB_NAME" \
    --query 'RouteTables[0].RouteTableId' --output text --region "$AWS_REGION")

  if [ -z "$RTB_ID" ] || [ "$RTB_ID" == "None" ]; then
    err "Route table '$RTB_NAME' não encontrada, pulando..."
  else
    # Desassociar antes de deletar
    ASSOC_IDS=$(aws ec2 describe-route-tables \
      --route-table-ids "$RTB_ID" \
      --query 'RouteTables[0].Associations[?Main==`false`].RouteTableAssociationId' \
      --output text --region "$AWS_REGION")

    for ASSOC_ID in $ASSOC_IDS; do
      log "Desassociando route table: $ASSOC_ID..."
      aws ec2 disassociate-route-table --association-id "$ASSOC_ID" --region "$AWS_REGION"
    done

    log "Deletando Route Table: $RTB_ID ($RTB_NAME)..."
    aws ec2 delete-route-table --route-table-id "$RTB_ID" --region "$AWS_REGION"
    ok "Route table deletada: $RTB_ID"
  fi
done

# =============================================================================
# PARTE 6 — DELETAR NAT GATEWAY + ELASTIC IP
# =============================================================================
echo ""
echo -e "${CYAN}>>> PARTE 6 — Deletando NAT Gateway e Elastic IP${NC}"
echo ""

NAT_GW_ID=$(aws ec2 describe-nat-gateways \
  --filter "Name=tag:Name,Values=preset-cesarmiguel-nat-public1-us-east-1a" \
           "Name=state,Values=available,pending" \
  --query 'NatGateways[0].NatGatewayId' --output text --region "$AWS_REGION")

if [ -z "$NAT_GW_ID" ] || [ "$NAT_GW_ID" == "None" ]; then
  err "NAT Gateway não encontrado, pulando..."
else
  log "Deletando NAT Gateway: $NAT_GW_ID..."
  aws ec2 delete-nat-gateway --nat-gateway-id "$NAT_GW_ID" --region "$AWS_REGION" > /dev/null
  warn "Aguardando NAT Gateway ser deletado (pode levar ~1 min)..."
  aws ec2 wait nat-gateway-deleted --nat-gateway-ids "$NAT_GW_ID" --region "$AWS_REGION"
  ok "NAT Gateway deletado: $NAT_GW_ID"
fi

EIP_ALLOC_ID=$(aws ec2 describe-addresses \
  --filters "Name=tag:Name,Values=preset-cesarmiguel-eip-us-east-1a" \
  --query 'Addresses[0].AllocationId' --output text --region "$AWS_REGION")

if [ -z "$EIP_ALLOC_ID" ] || [ "$EIP_ALLOC_ID" == "None" ]; then
  err "Elastic IP não encontrado, pulando..."
else
  log "Liberando Elastic IP: $EIP_ALLOC_ID..."
  aws ec2 release-address --allocation-id "$EIP_ALLOC_ID" --region "$AWS_REGION"
  ok "Elastic IP liberado: $EIP_ALLOC_ID"
fi

# =============================================================================
# PARTE 7 — DESANEXAR E DELETAR INTERNET GATEWAY
# =============================================================================
echo ""
echo -e "${CYAN}>>> PARTE 7 — Deletando Internet Gateway${NC}"
echo ""

IGW_ID=$(aws ec2 describe-internet-gateways \
  --filters "Name=tag:Name,Values=preset-cesarmiguel-igw" \
  --query 'InternetGateways[0].InternetGatewayId' --output text --region "$AWS_REGION")

if [ -z "$IGW_ID" ] || [ "$IGW_ID" == "None" ]; then
  err "Internet Gateway não encontrado, pulando..."
else
  log "Desanexando Internet Gateway: $IGW_ID..."
  aws ec2 detach-internet-gateway \
    --internet-gateway-id "$IGW_ID" \
    --vpc-id "$VPC_ID" --region "$AWS_REGION"

  log "Deletando Internet Gateway: $IGW_ID..."
  aws ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID" --region "$AWS_REGION"
  ok "Internet Gateway deletado: $IGW_ID"
fi

# =============================================================================
# PARTE 8 — DELETAR SUBNETS
# =============================================================================
echo ""
echo -e "${CYAN}>>> PARTE 8 — Deletando Subnets${NC}"
echo ""

for SUBNET_NAME in "preset-cesarmiguel-subnet-public1-us-east-1a" "preset-cesarmiguel-subnet-private1-us-east-1a"; do
  SUBNET_ID=$(aws ec2 describe-subnets \
    --filters "Name=tag:Name,Values=$SUBNET_NAME" \
    --query 'Subnets[0].SubnetId' --output text --region "$AWS_REGION")

  if [ -z "$SUBNET_ID" ] || [ "$SUBNET_ID" == "None" ]; then
    err "Subnet '$SUBNET_NAME' não encontrada, pulando..."
  else
    log "Deletando Subnet: $SUBNET_ID ($SUBNET_NAME)..."
    aws ec2 delete-subnet --subnet-id "$SUBNET_ID" --region "$AWS_REGION"
    ok "Subnet deletada: $SUBNET_ID"
  fi
done

# =============================================================================
# PARTE 9 — DELETAR VPC
# =============================================================================
echo ""
echo -e "${CYAN}>>> PARTE 9 — Deletando VPC${NC}"
echo ""

log "Deletando VPC: $VPC_ID..."
aws ec2 delete-vpc --vpc-id "$VPC_ID" --region "$AWS_REGION"
ok "VPC deletada: $VPC_ID"

# =============================================================================
# RESUMO FINAL
# =============================================================================
echo ""
echo "=============================================="
echo -e "${GREEN}  ✅ Infraestrutura removida com sucesso!${NC}"
echo "=============================================="
echo ""
