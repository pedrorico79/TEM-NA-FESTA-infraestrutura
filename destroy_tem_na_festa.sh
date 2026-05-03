#!/bin/bash

# =============================================================
#  DESTROY - ARQUITETURA 3 CAMADAS NA AWS
#  Lê o arquivo deploy_summary_*.txt e remove todos os recursos.
# =============================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC}  $1"; }
log_ok()      { echo -e "${GREEN}[OK]${NC}    $1"; }
log_skip()    { echo -e "${YELLOW}[SKIP]${NC}  $1 — já removido ou não encontrado."; }
log_error()   { echo -e "${RED}[ERRO]${NC}  $1"; exit 1; }
log_section() { echo -e "\n${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${YELLOW}  $1${NC}"; echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

AWS_REGION="us-east-1"

# ================================================================
#  FUNÇÃO: extrai o valor de uma variável do summary
#  Pega somente o primeiro token (antes de qualquer espaço/parêntese)
# ================================================================
get_var() {
    local VAR_NAME="$1"
    local FILE="$2"
    grep -E "^${VAR_NAME}=" "$FILE" | head -1 | cut -d'=' -f2 | awk '{print $1}' | tr -d '()'
}

# ================================================================
#  FUNÇÃO: aguarda NAT Gateway atingir estado 'deleted'
#  (aws ec2 wait nat-gateway-deleted não existe na CLI)
# ================================================================
wait_nat_deleted() {
    local NAT_ID="$1"
    log_info "Aguardando NAT Gateway ser removido (pode levar ~60s)..."
    for i in $(seq 1 30); do
        STATE=$(aws ec2 describe-nat-gateways \
          --nat-gateway-ids "$NAT_ID" \
          --query 'NatGateways[0].State' \
          --region "$AWS_REGION" \
          --output text 2>/dev/null || echo "deleted")
        if [[ "$STATE" == "deleted" ]]; then
            log_ok "NAT Gateway removido."
            return 0
        fi
        echo -e "    Estado atual: ${STATE} — aguardando... (${i}/30)"
        sleep 10
    done
    log_error "Timeout aguardando NAT Gateway ser deletado. Verifique no console AWS."
}

# ================================================================
#  LOCALIZA O SUMMARY
# ================================================================

SUMMARY_FILE=$(ls -t deploy_summary_*.txt 2>/dev/null | head -1 || true)

if [[ -z "$SUMMARY_FILE" ]]; then
    log_error "Nenhum arquivo deploy_summary_*.txt encontrado no diretório atual."
fi

log_info "Usando arquivo de summary: $SUMMARY_FILE"

# ================================================================
#  LÊ CADA VARIÁVEL INDIVIDUALMENTE DO SUMMARY
# ================================================================

VPC_ID=$(get_var "VPC_ID" "$SUMMARY_FILE")
IGW_ID=$(get_var "IGW_ID" "$SUMMARY_FILE")
NAT_GW_ID=$(get_var "NAT_GW_ID" "$SUMMARY_FILE")
EIP_ALLOC_ID=$(get_var "EIP_ALLOC_ID" "$SUMMARY_FILE")

SUBNET_PUBLIC_1=$(get_var "SUBNET_PUBLIC_1" "$SUMMARY_FILE")
SUBNET_PUBLIC_2=$(get_var "SUBNET_PUBLIC_2" "$SUMMARY_FILE")
SUBNET_PRIVATE_FRONT1=$(get_var "SUBNET_PRIVATE_FRONT1" "$SUMMARY_FILE")
SUBNET_PRIVATE_FRONT2=$(get_var "SUBNET_PRIVATE_FRONT2" "$SUMMARY_FILE")
SUBNET_PRIVATE_BACKEND=$(get_var "SUBNET_PRIVATE_BACKEND" "$SUMMARY_FILE")
SUBNET_PRIVATE_DB=$(get_var "SUBNET_PRIVATE_DB" "$SUMMARY_FILE")

SG_BASTION=$(get_var "SG_BASTION" "$SUMMARY_FILE")
SG_ALB=$(get_var "SG_ALB" "$SUMMARY_FILE")
SG_FRONTEND=$(get_var "SG_FRONTEND" "$SUMMARY_FILE")
SG_BACKEND=$(get_var "SG_BACKEND" "$SUMMARY_FILE")
SG_DB=$(get_var "SG_DB" "$SUMMARY_FILE")

INSTANCE_BASTION=$(get_var "INSTANCE_BASTION" "$SUMMARY_FILE")
INSTANCE_FRONTEND_1=$(get_var "INSTANCE_FRONTEND_1" "$SUMMARY_FILE")
INSTANCE_FRONTEND_2=$(get_var "INSTANCE_FRONTEND_2" "$SUMMARY_FILE")
INSTANCE_BACKEND=$(get_var "INSTANCE_BACKEND" "$SUMMARY_FILE")
INSTANCE_DB=$(get_var "INSTANCE_DB" "$SUMMARY_FILE")

ALB_ARN=$(get_var "ALB_ARN" "$SUMMARY_FILE")
TG_ARN=$(get_var "TG_ARN" "$SUMMARY_FILE")

# ================================================================
#  VALIDA VARIÁVEIS
# ================================================================

ERRORS=0
for VAR_NAME in VPC_ID IGW_ID NAT_GW_ID EIP_ALLOC_ID \
                SUBNET_PUBLIC_1 SUBNET_PUBLIC_2 \
                SUBNET_PRIVATE_FRONT1 SUBNET_PRIVATE_FRONT2 \
                SUBNET_PRIVATE_BACKEND SUBNET_PRIVATE_DB \
                SG_BASTION SG_ALB SG_FRONTEND SG_BACKEND SG_DB \
                INSTANCE_BASTION INSTANCE_FRONTEND_1 INSTANCE_FRONTEND_2 \
                INSTANCE_BACKEND INSTANCE_DB ALB_ARN TG_ARN; do
    VAL="${!VAR_NAME}"
    if [[ -z "$VAL" ]]; then
        echo -e "${RED}[ERRO]${NC}  Variável '$VAR_NAME' não encontrada ou vazia no summary."
        ERRORS=$((ERRORS + 1))
    fi
done

if [[ $ERRORS -gt 0 ]]; then
    log_error "$ERRORS variável(is) não encontrada(s). Verifique: $SUMMARY_FILE"
fi

# ================================================================
#  CONFIRMAÇÃO
# ================================================================

echo ""
echo -e "${RED}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${RED}║   ATENÇÃO: ESTA AÇÃO É IRREVERSÍVEL!                    ║${NC}"
echo -e "${RED}║   Todos os recursos abaixo serão PERMANENTEMENTE        ║${NC}"
echo -e "${RED}║   deletados da sua conta AWS.                           ║${NC}"
echo -e "${RED}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo    "  VPC:         $VPC_ID"
echo    "  IGW:         $IGW_ID"
echo    "  NAT Gateway: $NAT_GW_ID"
echo    "  ALB:         $ALB_ARN"
echo    "  Instâncias:"
echo    "    Bastion:    $INSTANCE_BASTION"
echo    "    Frontend 1: $INSTANCE_FRONTEND_1"
echo    "    Frontend 2: $INSTANCE_FRONTEND_2"
echo    "    Backend:    $INSTANCE_BACKEND"
echo    "    DB:         $INSTANCE_DB"
echo ""
read -r -p "  Digite 'DESTROY' para confirmar: " CONFIRM

if [[ "$CONFIRM" != "DESTROY" ]]; then
    echo ""
    echo -e "${YELLOW}Operação cancelada pelo usuário.${NC}"
    exit 0
fi

echo ""

# ================================================================
#  1. ALB — LISTENERS E LOAD BALANCER
# ================================================================

log_section "1/8 — Removendo Load Balancer e Listeners"

LISTENERS=$(aws elbv2 describe-listeners \
  --load-balancer-arn "$ALB_ARN" \
  --region "$AWS_REGION" \
  --query 'Listeners[*].ListenerArn' \
  --output text 2>/dev/null || true)

for LISTENER_ARN in $LISTENERS; do
    log_info "Deletando listener: $LISTENER_ARN"
    aws elbv2 delete-listener \
      --listener-arn "$LISTENER_ARN" \
      --region "$AWS_REGION"
done

log_info "Deletando ALB..."
aws elbv2 delete-load-balancer \
  --load-balancer-arn "$ALB_ARN" \
  --region "$AWS_REGION"

log_info "Aguardando ALB ser completamente removido..."
aws elbv2 wait load-balancers-deleted \
  --load-balancer-arns "$ALB_ARN" \
  --region "$AWS_REGION"

log_ok "ALB removido."

# ================================================================
#  2. TARGET GROUP
# ================================================================

log_section "2/8 — Removendo Target Group"

aws elbv2 delete-target-group \
  --target-group-arn "$TG_ARN" \
  --region "$AWS_REGION"

log_ok "Target Group removido."

# ================================================================
#  3. INSTÂNCIAS EC2
# ================================================================

log_section "3/8 — Terminando instâncias EC2"

ALL_INSTANCES="$INSTANCE_BASTION $INSTANCE_FRONTEND_1 $INSTANCE_FRONTEND_2 $INSTANCE_BACKEND $INSTANCE_DB"

log_info "Terminando: $ALL_INSTANCES"
aws ec2 terminate-instances \
  --instance-ids $ALL_INSTANCES \
  --region "$AWS_REGION" > /dev/null

log_info "Aguardando todas as instâncias serem terminadas (~2 minutos)..."
aws ec2 wait instance-terminated \
  --instance-ids $ALL_INSTANCES \
  --region "$AWS_REGION"

log_ok "Todas as instâncias terminadas."

# ================================================================
#  4. NAT GATEWAY + ELASTIC IP
# ================================================================

log_section "4/8 — Removendo NAT Gateway e Elastic IP"

log_info "Deletando NAT Gateway: $NAT_GW_ID"
aws ec2 delete-nat-gateway \
  --nat-gateway-id "$NAT_GW_ID" \
  --region "$AWS_REGION" > /dev/null

# Polling manual — 'aws ec2 wait nat-gateway-deleted' não existe na CLI
wait_nat_deleted "$NAT_GW_ID"

log_info "Liberando Elastic IP: $EIP_ALLOC_ID"
aws ec2 release-address \
  --allocation-id "$EIP_ALLOC_ID" \
  --region "$AWS_REGION"

log_ok "Elastic IP liberado."

# ================================================================
#  5. SECURITY GROUPS
# ================================================================

log_section "5/8 — Removendo Security Groups"

log_info "Removendo regras de dependência entre Security Groups..."

aws ec2 revoke-security-group-ingress --group-id "$SG_FRONTEND" \
  --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":80,\"ToPort\":80,\"UserIdGroupPairs\":[{\"GroupId\":\"$SG_ALB\"}]}]" \
  --region "$AWS_REGION" 2>/dev/null || true

aws ec2 revoke-security-group-ingress --group-id "$SG_FRONTEND" \
  --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":22,\"ToPort\":22,\"UserIdGroupPairs\":[{\"GroupId\":\"$SG_BASTION\"}]}]" \
  --region "$AWS_REGION" 2>/dev/null || true

aws ec2 revoke-security-group-ingress --group-id "$SG_BACKEND" \
  --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":8080,\"ToPort\":8080,\"UserIdGroupPairs\":[{\"GroupId\":\"$SG_FRONTEND\"}]}]" \
  --region "$AWS_REGION" 2>/dev/null || true

aws ec2 revoke-security-group-ingress --group-id "$SG_BACKEND" \
  --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":22,\"ToPort\":22,\"UserIdGroupPairs\":[{\"GroupId\":\"$SG_BASTION\"}]}]" \
  --region "$AWS_REGION" 2>/dev/null || true

aws ec2 revoke-security-group-ingress --group-id "$SG_DB" \
  --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":3306,\"ToPort\":3306,\"UserIdGroupPairs\":[{\"GroupId\":\"$SG_BACKEND\"}]}]" \
  --region "$AWS_REGION" 2>/dev/null || true

aws ec2 revoke-security-group-ingress --group-id "$SG_DB" \
  --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":22,\"ToPort\":22,\"UserIdGroupPairs\":[{\"GroupId\":\"$SG_BASTION\"}]}]" \
  --region "$AWS_REGION" 2>/dev/null || true

log_ok "Regras de dependência removidas."

for SG_ID in "$SG_DB" "$SG_BACKEND" "$SG_FRONTEND" "$SG_ALB" "$SG_BASTION"; do
    log_info "Deletando Security Group: $SG_ID"
    aws ec2 delete-security-group \
      --group-id "$SG_ID" \
      --region "$AWS_REGION" 2>/dev/null \
      && log_ok "SG $SG_ID removido." \
      || log_skip "SG $SG_ID"
done

# ================================================================
#  6. ROUTE TABLES
# ================================================================

log_section "6/8 — Removendo Tabelas de Roteamento"

RT_IDS=$(aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'RouteTables[?Associations[0].Main!=`true`].RouteTableId' \
  --region "$AWS_REGION" \
  --output text 2>/dev/null || true)

for RT_ID in $RT_IDS; do
    ASSOC_IDS=$(aws ec2 describe-route-tables \
      --route-table-ids "$RT_ID" \
      --query 'RouteTables[0].Associations[?!Main].RouteTableAssociationId' \
      --region "$AWS_REGION" \
      --output text 2>/dev/null || true)

    for ASSOC_ID in $ASSOC_IDS; do
        log_info "Desassociando: $ASSOC_ID"
        aws ec2 disassociate-route-table \
          --association-id "$ASSOC_ID" \
          --region "$AWS_REGION" 2>/dev/null || true
    done

    log_info "Deletando Route Table: $RT_ID"
    aws ec2 delete-route-table \
      --route-table-id "$RT_ID" \
      --region "$AWS_REGION" 2>/dev/null \
      && log_ok "Route Table $RT_ID removida." \
      || log_skip "RT $RT_ID"
done

# ================================================================
#  7. SUB-REDES
# ================================================================

log_section "7/8 — Removendo Sub-redes"

for SUBNET_ID in "$SUBNET_PUBLIC_1" "$SUBNET_PUBLIC_2" \
                 "$SUBNET_PRIVATE_FRONT1" "$SUBNET_PRIVATE_FRONT2" \
                 "$SUBNET_PRIVATE_BACKEND" "$SUBNET_PRIVATE_DB"; do
    log_info "Deletando Sub-rede: $SUBNET_ID"
    aws ec2 delete-subnet \
      --subnet-id "$SUBNET_ID" \
      --region "$AWS_REGION" 2>/dev/null \
      && log_ok "Sub-rede $SUBNET_ID removida." \
      || log_skip "Subnet $SUBNET_ID"
done

# ================================================================
#  8. INTERNET GATEWAY + VPC
# ================================================================

log_section "8/8 — Removendo Internet Gateway e VPC"

log_info "Desanexando Internet Gateway: $IGW_ID da VPC: $VPC_ID"
aws ec2 detach-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION" 2>/dev/null || log_skip "IGW já desanexado"

log_info "Deletando Internet Gateway: $IGW_ID"
aws ec2 delete-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --region "$AWS_REGION" 2>/dev/null \
  && log_ok "Internet Gateway removido." \
  || log_skip "IGW $IGW_ID"

log_info "Deletando VPC: $VPC_ID"
aws ec2 delete-vpc \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION" 2>/dev/null \
  && log_ok "VPC removida." \
  || log_skip "VPC $VPC_ID"

# ================================================================
#  RESUMO FINAL
# ================================================================

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║      DESTROY CONCLUÍDO COM SUCESSO!                 ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo    "  Recursos destruídos:"
echo    "    ✓ Application Load Balancer + Listeners"
echo    "    ✓ Target Group"
echo    "    ✓ 5 Instâncias EC2 (Bastion, 2x Frontend, Backend, DB)"
echo    "    ✓ NAT Gateway + Elastic IP"
echo    "    ✓ 5 Security Groups"
echo    "    ✓ Route Tables"
echo    "    ✓ 6 Sub-redes"
echo    "    ✓ Internet Gateway"
echo    "    ✓ VPC"
echo ""
echo -e "${YELLOW}  Verifique no console AWS se não restou nenhum recurso${NC}"
echo -e "${YELLOW}  ativo para evitar cobranças inesperadas.${NC}"
echo ""

mv "$SUMMARY_FILE" "${SUMMARY_FILE%.txt}_DESTROYED.txt"
log_ok "Summary arquivado como: ${SUMMARY_FILE%.txt}_DESTROYED.txt"
echo ""
