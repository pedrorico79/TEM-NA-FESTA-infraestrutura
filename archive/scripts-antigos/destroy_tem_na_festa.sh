#!/bin/bash

# =============================================================
#  DESTROY POR TAG - ARQUITETURA 3 CAMADAS NA AWS
#  Descobre e remove todos os recursos pelo tag Project=PROJECT_NAME
#  Útil quando não existe deploy_summary (deploy falhou no meio).
# =============================================================

set -uo pipefail
export AWS_PAGER=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC}  $1"; }
log_ok()      { echo -e "${GREEN}[OK]${NC}    $1"; }
log_skip()    { echo -e "${YELLOW}[SKIP]${NC}  $1 — já removido ou não encontrado."; }
log_warn()    { echo -e "${YELLOW}[AVISO]${NC} $1"; }
log_error()   { echo -e "${RED}[ERRO]${NC}  $1"; exit 1; }
log_section() {
    echo -e "\n${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}  $1${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# Roda um comando e loga ok/skip sem quebrar com set -e
try_cmd() {
    local label="$1"; shift
    if "$@" 2>/dev/null; then
        log_ok "$label"
    else
        log_skip "$label"
    fi
}

# ================================================================
#  CONFIGURAÇÃO — ajuste se usou outro nome de projeto
# ================================================================

AWS_REGION="us-east-1"
PROJECT_NAME="minha-app"

TAG_FILTER="Name=tag:Project,Values=${PROJECT_NAME}"

# ================================================================
#  FUNÇÕES DE ESPERA
# ================================================================

wait_nat_deleted() {
    local NAT_ID="$1"
    log_info "Aguardando NAT Gateway ser removido (~60s)..."
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
        echo -e "    Estado: ${STATE} — aguardando... (${i}/30)"
        sleep 10
    done
    log_warn "Timeout no NAT Gateway — verifique no console."
}

wait_rds_deleted() {
    local RDS_ID="$1"
    log_info "Aguardando RDS ser removido (~5-10 minutos)..."
    for i in $(seq 1 60); do
        STATE=$(aws rds describe-db-instances \
          --db-instance-identifier "$RDS_ID" \
          --query 'DBInstances[0].DBInstanceStatus' \
          --region "$AWS_REGION" \
          --output text 2>/dev/null || echo "deleted")
        if [[ "$STATE" == "deleted" || "$STATE" == "None" ]]; then
            log_ok "RDS removido."
            return 0
        fi
        echo -e "    Estado: ${STATE} — aguardando... (${i}/60)"
        sleep 10
    done
    log_warn "Timeout no RDS — verifique no console."
}

# ================================================================
#  DESCOBERTA DOS RECURSOS VIA TAG
# ================================================================

log_section "Descobrindo recursos com tag Project=${PROJECT_NAME}"

none_to_empty() { [[ "$1" == "None" || "$1" == "null" ]] && echo "" || echo "$1"; }

VPC_ID=$(none_to_empty "$(aws ec2 describe-vpcs \
  --filters "$TAG_FILTER" \
  --query 'Vpcs[0].VpcId' --output text --region "$AWS_REGION" 2>/dev/null || true)")

IGW_ID=$(none_to_empty "$(aws ec2 describe-internet-gateways \
  --filters "$TAG_FILTER" \
  --query 'InternetGateways[0].InternetGatewayId' --output text --region "$AWS_REGION" 2>/dev/null || true)")

NAT_GW_ID=$(none_to_empty "$(aws ec2 describe-nat-gateways \
  --filter "$TAG_FILTER" "Name=state,Values=available,pending" \
  --query 'NatGateways[0].NatGatewayId' --output text --region "$AWS_REGION" 2>/dev/null || true)")

EIP_ALLOC_ID=""
if [[ -n "$NAT_GW_ID" ]]; then
    EIP_ALLOC_ID=$(none_to_empty "$(aws ec2 describe-nat-gateways \
      --nat-gateway-ids "$NAT_GW_ID" \
      --query 'NatGateways[0].NatGatewayAddresses[0].AllocationId' \
      --output text --region "$AWS_REGION" 2>/dev/null || true)")
fi

INSTANCE_IDS=$(aws ec2 describe-instances \
  --filters "$TAG_FILTER" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[*].Instances[*].InstanceId' \
  --output text --region "$AWS_REGION" 2>/dev/null || true)

ALB_ARN=$(none_to_empty "$(aws elbv2 describe-load-balancers \
  --region "$AWS_REGION" \
  --query "LoadBalancers[?contains(LoadBalancerName, '${PROJECT_NAME}')].LoadBalancerArn | [0]" \
  --output text 2>/dev/null || true)")

TG_ARNS=$(aws elbv2 describe-target-groups \
  --region "$AWS_REGION" \
  --query "TargetGroups[?contains(TargetGroupName, '${PROJECT_NAME}')].TargetGroupArn" \
  --output text 2>/dev/null || true)

RDS_IDENTIFIER=$(none_to_empty "$(aws rds describe-db-instances \
  --region "$AWS_REGION" \
  --query "DBInstances[?contains(DBInstanceIdentifier, '${PROJECT_NAME}') && DBInstanceStatus!='deleting'].DBInstanceIdentifier | [0]" \
  --output text 2>/dev/null || true)")

RDS_SUBNET_GROUP=$(none_to_empty "$(aws rds describe-db-subnet-groups \
  --region "$AWS_REGION" \
  --query "DBSubnetGroups[?contains(DBSubnetGroupName, '${PROJECT_NAME}')].DBSubnetGroupName | [0]" \
  --output text 2>/dev/null || true)")

EFS_ID=$(none_to_empty "$(aws efs describe-file-systems \
  --region "$AWS_REGION" \
  --query "FileSystems[?Tags[?Key=='Project' && Value=='${PROJECT_NAME}']].FileSystemId | [0]" \
  --output text 2>/dev/null || true)")

SG_IDS=$(aws ec2 describe-security-groups \
  --filters "$TAG_FILTER" \
  --query 'SecurityGroups[*].GroupId' \
  --output text --region "$AWS_REGION" 2>/dev/null || true)

SUBNET_IDS=$(aws ec2 describe-subnets \
  --filters "$TAG_FILTER" \
  --query 'Subnets[*].SubnetId' \
  --output text --region "$AWS_REGION" 2>/dev/null || true)

RT_IDS=""
if [[ -n "$VPC_ID" ]]; then
    RT_IDS=$(aws ec2 describe-route-tables \
      --filters "Name=vpc-id,Values=$VPC_ID" \
      --query 'RouteTables[?Associations[0].Main!=`true`].RouteTableId' \
      --output text --region "$AWS_REGION" 2>/dev/null || true)
fi

# ================================================================
#  EXIBE O QUE FOI ENCONTRADO E PEDE CONFIRMAÇÃO
# ================================================================

echo ""
echo -e "${BLUE}  Recursos encontrados:${NC}"
echo    "  VPC:           ${VPC_ID:-<não encontrado>}"
echo    "  IGW:           ${IGW_ID:-<não encontrado>}"
echo    "  NAT Gateway:   ${NAT_GW_ID:-<não encontrado>}"
echo    "  EFS:           ${EFS_ID:-<não encontrado>}"
echo    "  RDS:           ${RDS_IDENTIFIER:-<não encontrado>}"
echo    "  ALB:           ${ALB_ARN:-<não encontrado>}"
echo    "  Target Groups: ${TG_ARNS:-<não encontrado>}"
echo    "  Instâncias:    ${INSTANCE_IDS:-<nenhuma>}"
echo    "  Security Gps:  ${SG_IDS:-<não encontrado>}"
echo    "  Sub-redes:     ${SUBNET_IDS:-<não encontrado>}"
echo    "  Route Tables:  ${RT_IDS:-<não encontrado>}"
echo ""

echo -e "${RED}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${RED}║   ATENÇÃO: ESTA AÇÃO É IRREVERSÍVEL!                    ║${NC}"
echo -e "${RED}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
read -r -p "  Digite 'DESTROY' para confirmar: " CONFIRM

if [[ "$CONFIRM" != "DESTROY" ]]; then
    echo -e "${YELLOW}Operação cancelada.${NC}"
    exit 0
fi

echo ""

# ================================================================
#  1. ALB + LISTENERS
# ================================================================

log_section "1/10 — Removendo Load Balancer e Listeners"

if [[ -n "$ALB_ARN" ]]; then
    LISTENERS=$(aws elbv2 describe-listeners \
      --load-balancer-arn "$ALB_ARN" \
      --query 'Listeners[*].ListenerArn' --output text --region "$AWS_REGION" 2>/dev/null || true)
    for L in $LISTENERS; do
        log_info "Deletando listener: $L"
        aws elbv2 delete-listener --listener-arn "$L" --region "$AWS_REGION" 2>/dev/null || true
    done
    log_info "Deletando ALB..."
    aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN" --region "$AWS_REGION"
    log_info "Aguardando ALB ser removido..."
    aws elbv2 wait load-balancers-deleted --load-balancer-arns "$ALB_ARN" --region "$AWS_REGION"
    log_ok "ALB removido."
else
    log_skip "ALB"
fi

# ================================================================
#  2. TARGET GROUPS
# ================================================================

log_section "2/10 — Removendo Target Groups"

if [[ -n "$TG_ARNS" ]]; then
    for TG in $TG_ARNS; do
        log_info "Deletando Target Group: $TG"
        try_cmd "Target Group $TG" aws elbv2 delete-target-group --target-group-arn "$TG" --region "$AWS_REGION"
    done
else
    log_skip "Target Groups"
fi

# ================================================================
#  3. INSTÂNCIAS EC2
# ================================================================

log_section "3/10 — Terminando instâncias EC2"

if [[ -n "$INSTANCE_IDS" ]]; then
    log_info "Terminando: $INSTANCE_IDS"
    aws ec2 terminate-instances --instance-ids $INSTANCE_IDS --region "$AWS_REGION" > /dev/null
    log_info "Aguardando instâncias serem terminadas..."
    aws ec2 wait instance-terminated --instance-ids $INSTANCE_IDS --region "$AWS_REGION"
    log_ok "Instâncias terminadas."
else
    log_skip "Instâncias EC2"
fi

# ================================================================
#  4. RDS MYSQL
# ================================================================

log_section "4/10 — Removendo RDS MySQL"

if [[ -n "$RDS_IDENTIFIER" ]]; then
    log_info "Desabilitando deletion protection..."
    aws rds modify-db-instance \
      --db-instance-identifier "$RDS_IDENTIFIER" \
      --no-deletion-protection --apply-immediately \
      --region "$AWS_REGION" > /dev/null
    sleep 30
    log_info "Deletando RDS (sem snapshot)..."
    aws rds delete-db-instance \
      --db-instance-identifier "$RDS_IDENTIFIER" \
      --skip-final-snapshot --delete-automated-backups \
      --region "$AWS_REGION" > /dev/null
    wait_rds_deleted "$RDS_IDENTIFIER"
else
    log_skip "RDS"
fi

if [[ -n "$RDS_SUBNET_GROUP" ]]; then
    log_info "Removendo RDS Subnet Group: $RDS_SUBNET_GROUP"
    try_cmd "RDS Subnet Group" aws rds delete-db-subnet-group \
      --db-subnet-group-name "$RDS_SUBNET_GROUP" --region "$AWS_REGION"
else
    log_skip "RDS Subnet Group"
fi

# ================================================================
#  5. EFS — MOUNT TARGETS + FILE SYSTEM
# ================================================================

log_section "5/10 — Removendo EFS e Mount Targets"

if [[ -n "$EFS_ID" ]]; then
    MT_IDS=$(aws efs describe-mount-targets \
      --file-system-id "$EFS_ID" \
      --query 'MountTargets[*].MountTargetId' --output text --region "$AWS_REGION" 2>/dev/null || true)

    for MT in $MT_IDS; do
        log_info "Deletando Mount Target: $MT"
        aws efs delete-mount-target --mount-target-id "$MT" --region "$AWS_REGION" 2>/dev/null || true
    done

    if [[ -n "$MT_IDS" ]]; then
        log_info "Aguardando Mount Targets serem removidos..."
        for i in $(seq 1 18); do
            REMAINING=$(aws efs describe-mount-targets \
              --file-system-id "$EFS_ID" \
              --query 'length(MountTargets)' --output text --region "$AWS_REGION" 2>/dev/null || echo "0")
            if [[ "$REMAINING" == "0" ]]; then
                break
            fi
            echo -e "    Restantes: ${REMAINING} — aguardando... (${i}/18)"
            sleep 10
        done
    fi

    log_info "Deletando EFS: $EFS_ID"
    try_cmd "EFS $EFS_ID" aws efs delete-file-system --file-system-id "$EFS_ID" --region "$AWS_REGION"
else
    log_skip "EFS"
fi

# ================================================================
#  6. NAT GATEWAY + ELASTIC IP
# ================================================================

log_section "6/10 — Removendo NAT Gateway e Elastic IP"

if [[ -n "$NAT_GW_ID" ]]; then
    log_info "Deletando NAT Gateway: $NAT_GW_ID"
    aws ec2 delete-nat-gateway --nat-gateway-id "$NAT_GW_ID" --region "$AWS_REGION" > /dev/null
    wait_nat_deleted "$NAT_GW_ID"
else
    log_skip "NAT Gateway"
fi

if [[ -n "$EIP_ALLOC_ID" ]]; then
    log_info "Liberando Elastic IP: $EIP_ALLOC_ID"
    try_cmd "Elastic IP" aws ec2 release-address --allocation-id "$EIP_ALLOC_ID" --region "$AWS_REGION"
else
    log_skip "Elastic IP"
fi

# ================================================================
#  7. SECURITY GROUPS
# ================================================================

log_section "7/10 — Removendo Security Groups"

if [[ -n "$SG_IDS" ]]; then
    log_info "Revogando todas as regras de referência cruzada entre SGs..."
    for SG_ID in $SG_IDS; do
        RULES=$(aws ec2 describe-security-groups --group-ids "$SG_ID" \
          --query 'SecurityGroups[0].IpPermissions' --output json --region "$AWS_REGION" 2>/dev/null || echo "[]")
        if [[ "$RULES" != "[]" && "$RULES" != "null" && "$RULES" != "" ]]; then
            aws ec2 revoke-security-group-ingress \
              --group-id "$SG_ID" \
              --ip-permissions "$RULES" \
              --region "$AWS_REGION" 2>/dev/null || true
        fi
    done
    log_ok "Regras revogadas."

    for SG_ID in $SG_IDS; do
        log_info "Deletando SG: $SG_ID"
        try_cmd "SG $SG_ID" aws ec2 delete-security-group --group-id "$SG_ID" --region "$AWS_REGION"
    done
else
    log_skip "Security Groups"
fi

# ================================================================
#  8. ROUTE TABLES
# ================================================================

log_section "8/10 — Removendo Tabelas de Roteamento"

if [[ -n "$RT_IDS" ]]; then
    for RT_ID in $RT_IDS; do
        ASSOC_IDS=$(aws ec2 describe-route-tables --route-table-ids "$RT_ID" \
          --query 'RouteTables[0].Associations[?!Main].RouteTableAssociationId' \
          --output text --region "$AWS_REGION" 2>/dev/null || true)
        for ASSOC_ID in $ASSOC_IDS; do
            aws ec2 disassociate-route-table --association-id "$ASSOC_ID" --region "$AWS_REGION" 2>/dev/null || true
        done
        log_info "Deletando Route Table: $RT_ID"
        try_cmd "RT $RT_ID" aws ec2 delete-route-table --route-table-id "$RT_ID" --region "$AWS_REGION"
    done
else
    log_skip "Route Tables"
fi

# ================================================================
#  9. SUB-REDES
# ================================================================

log_section "9/10 — Removendo Sub-redes"

if [[ -n "$SUBNET_IDS" ]]; then
    for SUBNET_ID in $SUBNET_IDS; do
        log_info "Deletando subnet: $SUBNET_ID"
        try_cmd "Subnet $SUBNET_ID" aws ec2 delete-subnet --subnet-id "$SUBNET_ID" --region "$AWS_REGION"
    done
else
    log_skip "Sub-redes"
fi

# ================================================================
#  10. INTERNET GATEWAY + VPC
# ================================================================

log_section "10/10 — Removendo Internet Gateway e VPC"

if [[ -n "$IGW_ID" && -n "$VPC_ID" ]]; then
    log_info "Desanexando IGW..."
    aws ec2 detach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" \
      --region "$AWS_REGION" 2>/dev/null || true
fi

if [[ -n "$IGW_ID" ]]; then
    log_info "Deletando IGW: $IGW_ID"
    try_cmd "Internet Gateway" aws ec2 delete-internet-gateway \
      --internet-gateway-id "$IGW_ID" --region "$AWS_REGION"
else
    log_skip "Internet Gateway"
fi

if [[ -n "$VPC_ID" ]]; then

    # -- Subnets sem tag que possam ter ficado para tras ----------
    log_info "Verificando subnets restantes na VPC (incluindo sem tag)..."
    REMAINING_SUBNETS=$(aws ec2 describe-subnets \
      --filters "Name=vpc-id,Values=$VPC_ID" \
      --query 'Subnets[*].SubnetId' --output text --region "$AWS_REGION" 2>/dev/null || true)
    for SUBNET_ID in $REMAINING_SUBNETS; do
        log_info "Deletando subnet restante: $SUBNET_ID"
        aws ec2 delete-subnet --subnet-id "$SUBNET_ID" --region "$AWS_REGION" 2>/dev/null || true
    done

    # -- ENIs orfas -- especialmente as do NAT Gateway -----------
    # A AWS mantem a ENI do NAT em "in-use" por varios minutos apos
    # o NAT chegar em "deleted". Aguardamos ela ficar "available".
    log_info "Verificando ENIs orfas na VPC..."
    ORPHAN_ENIS=$(aws ec2 describe-network-interfaces \
      --filters "Name=vpc-id,Values=$VPC_ID" \
      --query 'NetworkInterfaces[*].NetworkInterfaceId' \
      --output text --region "$AWS_REGION" 2>/dev/null || true)

    if [[ -n "$ORPHAN_ENIS" ]]; then
        log_info "ENIs encontradas: $ORPHAN_ENIS — aguardando liberacao (ate 5 min)..."
        for i in $(seq 1 30); do
            ALL_AVAILABLE=true
            for ENI_ID in $ORPHAN_ENIS; do
                STATUS=$(aws ec2 describe-network-interfaces \
                  --network-interface-ids "$ENI_ID" \
                  --query 'NetworkInterfaces[0].Status' \
                  --output text --region "$AWS_REGION" 2>/dev/null || echo "deleted")
                if [[ "$STATUS" == "in-use" ]]; then
                    ALL_AVAILABLE=false
                fi
            done
            if [[ "$ALL_AVAILABLE" == "true" ]]; then
                break
            fi
            echo -e "    ENIs ainda in-use — aguardando 10s... (${i}/30)"
            sleep 10
        done

        for ENI_ID in $ORPHAN_ENIS; do
            STATUS=$(aws ec2 describe-network-interfaces \
              --network-interface-ids "$ENI_ID" \
              --query 'NetworkInterfaces[0].Status' \
              --output text --region "$AWS_REGION" 2>/dev/null || echo "deleted")
            if [[ "$STATUS" == "available" ]]; then
                log_info "Deletando ENI: $ENI_ID"
                aws ec2 delete-network-interface \
                  --network-interface-id "$ENI_ID" \
                  --region "$AWS_REGION" 2>/dev/null || true
            else
                log_warn "ENI $ENI_ID ainda em status '$STATUS' — pode precisar de remocao manual."
            fi
        done
    else
        log_ok "Nenhuma ENI orfa encontrada."
    fi

    # -- Deletar VPC ---------------------------------------------
    log_info "Deletando VPC: $VPC_ID"
    for i in $(seq 1 6); do
        if aws ec2 delete-vpc --vpc-id "$VPC_ID" --region "$AWS_REGION" 2>/dev/null; then
            log_ok "VPC removida."
            break
        fi
        if [[ $i -lt 6 ]]; then
            log_warn "VPC ainda com dependencias — tentativa $i/6, aguardando 20s..."
            sleep 20
        else
            log_warn "VPC nao pode ser removida automaticamente. Verifique no console AWS."
        fi
    done

else
    log_skip "VPC"
fi

# ================================================================
#  RESUMO FINAL
# ================================================================

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║      DESTROY CONCLUÍDO!                             ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}  Verifique no console AWS se não restou nenhum recurso${NC}"
echo -e "${YELLOW}  ativo com a tag Project=${PROJECT_NAME}.${NC}"
echo ""