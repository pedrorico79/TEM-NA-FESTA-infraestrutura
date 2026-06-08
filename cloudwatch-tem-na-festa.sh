#!/bin/bash

# =============================================================
#  AUTOMAÇÃO DO MONITORAMENTO - AMAZON CLOUDWATCH
#  Projeto: Tem na Festa Chocolate
#  Infraestrutura: VPC 10.0.0.0/24 | Região: us-east-1
#  Camadas: ALB → EC2 Frontend (EFS) → EC2 Backend → RDS MySQL
#  + Bastion Host
#
#  PRÉ-REQUISITO OBRIGATÓRIO:
#  O CloudWatch Agent deve estar instalado e configurado em todas
#  as instâncias EC2 antes de executar este script.
#  Adicione o bloco abaixo ao user-data das instâncias EC2 no
#  script de deploy (deploy.sh), seção 8 — Criando Instâncias EC2:
#
#    apt-get install -y amazon-cloudwatch-agent
#    cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json <<'CW'
#    {
#      "metrics": {
#        "namespace": "CWAgent",
#        "metrics_collected": {
#          "mem": { "measurement": ["mem_used_percent"] },
#          "disk": {
#            "measurement": ["disk_used_percent"],
#            "resources": ["/"]
#          }
#        }
#      }
#    }
#    CW
#    /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
#      -a fetch-config -m ec2 -s \
#      -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json
# =============================================================

set -euo pipefail

# Necessário no Git Bash (Windows) para evitar conversão indevida de ARNs
export MSYS_NO_PATHCONV=1

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC}  $1"; }
log_ok()      { echo -e "${GREEN}[OK]${NC}    $1"; }
log_warn()    { echo -e "${YELLOW}[AVISO]${NC} $1"; }
log_error()   { echo -e "${RED}[ERRO]${NC}  $1"; exit 1; }
log_section() {
  echo -e "\n${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${YELLOW}  $1${NC}"
  echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# ================================================================
#  CONFIGURAÇÕES — devem ser idênticas às do deploy.sh
# ================================================================

AWS_REGION="us-east-1"
PROJECT_NAME="minha-app"

ALB_NAME="${PROJECT_NAME}-alb"
RDS_IDENTIFIER="${PROJECT_NAME}-mysql"

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

echo "=== Iniciando automação do CloudWatch para ${PROJECT_NAME} ==="

# ================================================================
#  0. CRIAÇÃO DO TÓPICO SNS (idempotente — não duplica se existir)
# ================================================================

log_section "0/4 — Criando/verificando tópico SNS"

SNS_TOPIC_ARN=$(aws sns create-topic \
    --name "${PROJECT_NAME}-alertas" \
    --region "$AWS_REGION" \
    --query 'TopicArn' \
    --output text)

log_ok "SNS Topic: $SNS_TOPIC_ARN"
log_warn "Confirme a inscrição do e-mail recebido na caixa de entrada para ativar os alertas."

# ================================================================
#  1. RESOLUÇÃO DINÂMICA DOS IDs DE INFRAESTRUTURA
# ================================================================

log_section "1/4 — Resolvendo IDs dos recursos na AWS"

# ── EFS ──────────────────────────────────────────────────────
EFS_ID=$(aws efs describe-file-systems \
    --query "FileSystems[?Tags[?Key=='Name' && Value=='${PROJECT_NAME}-efs']].FileSystemId" \
    --output text \
    --region "$AWS_REGION")

if [[ -z "$EFS_ID" || "$EFS_ID" == "None" ]]; then
    log_error "EFS '${PROJECT_NAME}-efs' não encontrado. Verifique se o deploy foi executado."
fi
log_ok "EFS: $EFS_ID"

# ── ALB ──────────────────────────────────────────────────────
ALB_ARN_FULL=$(aws elbv2 describe-load-balancers \
    --names "$ALB_NAME" \
    --query 'LoadBalancers[0].LoadBalancerArn' \
    --output text \
    --region "$AWS_REGION" 2>/dev/null || echo "None")

if [[ "$ALB_ARN_FULL" == "None" || -z "$ALB_ARN_FULL" ]]; then
    log_error "ALB '${ALB_NAME}' não encontrado. Verifique se o deploy foi executado."
fi

# Extrai o sufixo necessário para a dimensão do CloudWatch (ex: app/minha-app-alb/abc123)
ALB_ARN_SUFFIX=$(echo "$ALB_ARN_FULL" | sed 's/.*loadbalancer\///')
log_ok "ALB suffix: $ALB_ARN_SUFFIX"

# ── EC2 Instances ─────────────────────────────────────────────
# Helper para buscar e validar instância por tag Name
get_instance_id() {
    local tag_name="$1"
    local instance_id

    instance_id=$(aws ec2 describe-instances \
        --filters "Name=tag:Name,Values=${PROJECT_NAME}-${tag_name}" \
                  "Name=instance-state-name,Values=running" \
        --query "Reservations[0].Instances[0].InstanceId" \
        --output text \
        --region "$AWS_REGION")

    if [[ -z "$instance_id" || "$instance_id" == "None" ]]; then
        log_error "Instância '${PROJECT_NAME}-${tag_name}' não encontrada ou não está running."
    fi

    echo "$instance_id"
}

INSTANCE_FRONT_1A=$(get_instance_id "frontend-1a")
INSTANCE_FRONT_1B=$(get_instance_id "frontend-2b")    # tag conforme deploy.sh
INSTANCE_BACK_1A=$(get_instance_id  "backend-1a")
INSTANCE_BACK_1B=$(get_instance_id  "backend-1b")
INSTANCE_BASTION=$(get_instance_id  "bastion")

log_ok "Frontend 1a:  $INSTANCE_FRONT_1A"
log_ok "Frontend 1b:  $INSTANCE_FRONT_1B"
log_ok "Backend  1a:  $INSTANCE_BACK_1A"
log_ok "Backend  1b:  $INSTANCE_BACK_1B"
log_ok "Bastion:      $INSTANCE_BASTION"

# ================================================================
#  2. ALARMES CLOUDWATCH
# ================================================================

log_section "2/4 — Criando alarmes CloudWatch"

# ── 2a. StatusCheckFailed para todas as EC2 ───────────────────
# Detecta instância completamente inacessível (nível de hardware ou SO)
log_info "Criando alarmes de disponibilidade (StatusCheckFailed) para todas as EC2..."

declare -A INSTANCE_LABELS=(
    ["$INSTANCE_FRONT_1A"]="frontend-1a"
    ["$INSTANCE_FRONT_1B"]="frontend-2b"
    ["$INSTANCE_BACK_1A"]="backend-1a"
    ["$INSTANCE_BACK_1B"]="backend-1b"
    ["$INSTANCE_BASTION"]="bastion"
)

for INSTANCE_ID in "${!INSTANCE_LABELS[@]}"; do
    LABEL="${INSTANCE_LABELS[$INSTANCE_ID]}"
    aws cloudwatch put-metric-alarm \
        --alarm-name "${PROJECT_NAME}-ec2-down-${LABEL}" \
        --alarm-description "EC2 ${LABEL} inacessível — StatusCheckFailed ≥ 1 por 2 períodos" \
        --metric-name StatusCheckFailed \
        --namespace AWS/EC2 \
        --statistic Maximum \
        --period 60 \
        --threshold 1 \
        --comparison-operator GreaterThanOrEqualToThreshold \
        --dimensions Name=InstanceId,Value="$INSTANCE_ID" \
        --evaluation-periods 2 \
        --alarm-actions "$SNS_TOPIC_ARN" \
        --region "$AWS_REGION"
    log_ok "  Alarme criado: ec2-down-${LABEL}"
done

# ── 2b. CPU Alta — Backend ────────────────────────────────────
log_info "Criando alarmes de CPU para Backend..."

for BACKEND_ID in "$INSTANCE_BACK_1A" "$INSTANCE_BACK_1B"; do
    SUFFIX=$([ "$BACKEND_ID" == "$INSTANCE_BACK_1A" ] && echo "1a" || echo "1b")
    aws cloudwatch put-metric-alarm \
        --alarm-name "${PROJECT_NAME}-backend-cpu-alta-${SUFFIX}" \
        --alarm-description "CPU do Backend ${SUFFIX} acima de 80% por 15 minutos" \
        --metric-name CPUUtilization \
        --namespace AWS/EC2 \
        --statistic Average \
        --period 300 \
        --threshold 80 \
        --comparison-operator GreaterThanOrEqualToThreshold \
        --dimensions Name=InstanceId,Value="$BACKEND_ID" \
        --evaluation-periods 3 \
        --alarm-actions "$SNS_TOPIC_ARN" \
        --region "$AWS_REGION"
    log_ok "  Alarme criado: backend-cpu-alta-${SUFFIX}"
done

# ── 2c. Erros HTTP 5XX no ALB ─────────────────────────────────
log_info "Criando alarme de erros 5XX no ALB..."

aws cloudwatch put-metric-alarm \
    --alarm-name "${PROJECT_NAME}-alb-high-5xx-errors" \
    --alarm-description "Mais de 5 erros 5XX em 1 minuto no ALB — possível falha na aplicação" \
    --metric-name HTTPCode_Target_5XX_Count \
    --namespace AWS/ApplicationELB \
    --statistic Sum \
    --period 60 \
    --threshold 5 \
    --comparison-operator GreaterThanOrEqualToThreshold \
    --dimensions Name=LoadBalancer,Value="$ALB_ARN_SUFFIX" \
    --evaluation-periods 1 \
    --alarm-actions "$SNS_TOPIC_ARN" \
    --region "$AWS_REGION"

log_ok "Alarme criado: alb-high-5xx-errors"

# ── 2d. CPU Alta no RDS ───────────────────────────────────────
log_info "Criando alarme de CPU no RDS..."

aws cloudwatch put-metric-alarm \
    --alarm-name "${PROJECT_NAME}-rds-high-cpu" \
    --alarm-description "CPU do RDS MySQL acima de 85% por 5 minutos" \
    --metric-name CPUUtilization \
    --namespace AWS/RDS \
    --statistic Average \
    --period 300 \
    --threshold 85 \
    --comparison-operator GreaterThanOrEqualToThreshold \
    --dimensions Name=DBInstanceIdentifier,Value="$RDS_IDENTIFIER" \
    --evaluation-periods 1 \
    --alarm-actions "$SNS_TOPIC_ARN" \
    --region "$AWS_REGION"

log_ok "Alarme criado: rds-high-cpu"

# ── 2e. Disco Crítico no RDS ──────────────────────────────────
# Alerta quando restar menos de 2 GB livres (o RDS inicia com 20 GB alocados)
log_info "Criando alarme de disco livre no RDS..."

aws cloudwatch put-metric-alarm \
    --alarm-name "${PROJECT_NAME}-rds-disco-critico" \
    --alarm-description "RDS com menos de 2 GB livres — risco de falha nas gravações de pedidos" \
    --metric-name FreeStorageSpace \
    --namespace AWS/RDS \
    --statistic Average \
    --period 300 \
    --threshold 2147483648 \
    --comparison-operator LessThanOrEqualToThreshold \
    --dimensions Name=DBInstanceIdentifier,Value="$RDS_IDENTIFIER" \
    --evaluation-periods 1 \
    --alarm-actions "$SNS_TOPIC_ARN" \
    --region "$AWS_REGION"

log_ok "Alarme criado: rds-disco-critico"

# ── 2f. Habilitar logs de erro e slow query no RDS ────────────
log_info "Habilitando exportação de logs no RDS (error + slowquery)..."

aws rds modify-db-instance \
    --db-instance-identifier "$RDS_IDENTIFIER" \
    --cloudwatch-logs-export-configuration '{"EnableLogTypes":["error","slowquery"]}' \
    --region "$AWS_REGION" > /dev/null \
    || log_warn "Logs do RDS já configurados ou modificação idêntica em andamento."

log_ok "Logs RDS habilitados: error, slowquery"

# ================================================================
#  3. DASHBOARD CLOUDWATCH — NOC 3 CAMADAS
# ================================================================

log_section "3/4 — Criando dashboard de produção"

DASHBOARD_BODY=$(cat <<EOF
{
  "widgets": [

    {
      "type": "text",
      "x": 0, "y": 0, "width": 24, "height": 2,
      "properties": {
        "markdown": "# Dashboard — Tem na Festa Chocolate\nAmbiente: Produção | Região: ${AWS_REGION} | VPC: 10.0.0.0/24 | Camadas: ALB → Frontend (EFS) → Backend → RDS MySQL"
      }
    },

    {
      "type": "alarm",
      "x": 0, "y": 2, "width": 24, "height": 3,
      "properties": {
        "title": "Status dos Alarmes — Visão Geral",
        "alarms": [
          "arn:aws:cloudwatch:${AWS_REGION}:${ACCOUNT_ID}:alarm:${PROJECT_NAME}-ec2-down-frontend-1a",
          "arn:aws:cloudwatch:${AWS_REGION}:${ACCOUNT_ID}:alarm:${PROJECT_NAME}-ec2-down-frontend-2b",
          "arn:aws:cloudwatch:${AWS_REGION}:${ACCOUNT_ID}:alarm:${PROJECT_NAME}-ec2-down-backend-1a",
          "arn:aws:cloudwatch:${AWS_REGION}:${ACCOUNT_ID}:alarm:${PROJECT_NAME}-ec2-down-backend-1b",
          "arn:aws:cloudwatch:${AWS_REGION}:${ACCOUNT_ID}:alarm:${PROJECT_NAME}-ec2-down-bastion",
          "arn:aws:cloudwatch:${AWS_REGION}:${ACCOUNT_ID}:alarm:${PROJECT_NAME}-alb-high-5xx-errors",
          "arn:aws:cloudwatch:${AWS_REGION}:${ACCOUNT_ID}:alarm:${PROJECT_NAME}-rds-high-cpu",
          "arn:aws:cloudwatch:${AWS_REGION}:${ACCOUNT_ID}:alarm:${PROJECT_NAME}-rds-disco-critico"
        ]
      }
    },

    {
      "type": "metric",
      "x": 0, "y": 5, "width": 6, "height": 3,
      "properties": {
        "title": "Hosts Inoperantes (ALB Health Check)",
        "view": "singleValue",
        "metrics": [[
          "AWS/ApplicationELB", "UnHealthyHostCount",
          "LoadBalancer", "${ALB_ARN_SUFFIX}",
          { "stat": "Maximum", "color": "#d62728", "label": "Hosts com Falha" }
        ]],
        "region": "${AWS_REGION}"
      }
    },

    {
      "type": "metric",
      "x": 6, "y": 5, "width": 6, "height": 3,
      "properties": {
        "title": "Requisições por Minuto (ALB)",
        "view": "singleValue",
        "metrics": [[
          "AWS/ApplicationELB", "RequestCount",
          "LoadBalancer", "${ALB_ARN_SUFFIX}",
          { "stat": "Sum", "label": "Total Requisições (1 min)" }
        ]],
        "region": "${AWS_REGION}"
      }
    },

    {
      "type": "metric",
      "x": 12, "y": 5, "width": 6, "height": 3,
      "properties": {
        "title": "Conexões Ativas no RDS",
        "view": "singleValue",
        "metrics": [[
          "AWS/RDS", "DatabaseConnections",
          "DBInstanceIdentifier", "${RDS_IDENTIFIER}",
          { "stat": "Average", "color": "#1f77b4", "label": "Sessões MySQL" }
        ]],
        "region": "${AWS_REGION}"
      }
    },

    {
      "type": "metric",
      "x": 18, "y": 5, "width": 6, "height": 3,
      "properties": {
        "title": "Crédito de Burst EFS",
        "view": "singleValue",
        "metrics": [[
          "AWS/EFS", "BurstCreditBalance",
          "FileSystemId", "${EFS_ID}",
          { "stat": "Minimum", "label": "Saldo EFS" }
        ]],
        "region": "${AWS_REGION}"
      }
    },

    {
      "type": "text",
      "x": 0, "y": 8, "width": 24, "height": 1,
      "properties": {
        "markdown": "### Camada 1 — Entrada e tráfego web (ALB)"
      }
    },

    {
      "type": "metric",
      "x": 0, "y": 9, "width": 12, "height": 6,
      "properties": {
        "title": "Distribuição de Status HTTP por Minuto",
        "view": "timeSeries",
        "stacked": false,
        "metrics": [
          [ "AWS/ApplicationELB", "HTTPCode_Target_2XX_Count", "LoadBalancer", "${ALB_ARN_SUFFIX}", { "stat": "Sum", "label": "Sucesso (2XX)",       "color": "#2ca02c" } ],
          [ "AWS/ApplicationELB", "HTTPCode_Target_4XX_Count", "LoadBalancer", "${ALB_ARN_SUFFIX}", { "stat": "Sum", "label": "Erro Cliente (4XX)",  "color": "#ff7f0e" } ],
          [ "AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", "${ALB_ARN_SUFFIX}", { "stat": "Sum", "label": "Erro Servidor (5XX)", "color": "#d62728" } ]
        ],
        "region": "${AWS_REGION}"
      }
    },

    {
      "type": "metric",
      "x": 12, "y": 9, "width": 12, "height": 6,
      "properties": {
        "title": "Latência de Resposta da Aplicação (Target Response Time)",
        "view": "timeSeries",
        "stacked": false,
        "metrics": [[
          "AWS/ApplicationELB", "TargetResponseTime",
          "LoadBalancer", "${ALB_ARN_SUFFIX}",
          { "stat": "Average", "label": "Latência Média (s)", "color": "#9467bd" }
        ]],
        "region": "${AWS_REGION}"
      }
    },

    {
      "type": "text",
      "x": 0, "y": 15, "width": 24, "height": 1,
      "properties": {
        "markdown": "### Camada 2 — Servidores EC2 e armazenamento compartilhado (Frontend + Backend + EFS)"
      }
    },

    {
      "type": "metric",
      "x": 0, "y": 16, "width": 8, "height": 6,
      "properties": {
        "title": "CPU % por Instância EC2",
        "view": "timeSeries",
        "stacked": false,
        "metrics": [
          [ "AWS/EC2", "CPUUtilization", "InstanceId", "${INSTANCE_FRONT_1A}", { "stat": "Average", "label": "Frontend 1a" } ],
          [ "AWS/EC2", "CPUUtilization", "InstanceId", "${INSTANCE_FRONT_1B}", { "stat": "Average", "label": "Frontend 1b" } ],
          [ "AWS/EC2", "CPUUtilization", "InstanceId", "${INSTANCE_BACK_1A}",  { "stat": "Average", "label": "Backend 1a"  } ],
          [ "AWS/EC2", "CPUUtilization", "InstanceId", "${INSTANCE_BACK_1B}",  { "stat": "Average", "label": "Backend 1b"  } ]
        ],
        "annotations": { "horizontal": [{ "value": 80, "label": "Alerta", "color": "#d62728" }] },
        "region": "${AWS_REGION}"
      }
    },

    {
      "type": "metric",
      "x": 8, "y": 16, "width": 8, "height": 6,
      "properties": {
        "title": "Memória RAM % — Backend (CWAgent)",
        "view": "timeSeries",
        "stacked": false,
        "metrics": [
          [ "CWAgent", "mem_used_percent", "InstanceId", "${INSTANCE_BACK_1A}", { "stat": "Average", "label": "RAM Backend 1a" } ],
          [ "CWAgent", "mem_used_percent", "InstanceId", "${INSTANCE_BACK_1B}", { "stat": "Average", "label": "RAM Backend 1b" } ]
        ],
        "annotations": { "horizontal": [{ "value": 85, "label": "Alerta", "color": "#d62728" }] },
        "region": "${AWS_REGION}"
      }
    },

    {
      "type": "metric",
      "x": 16, "y": 16, "width": 8, "height": 6,
      "properties": {
        "title": "Gargalo de I/O no EFS (% do limite de burst)",
        "view": "timeSeries",
        "stacked": false,
        "metrics": [[
          "AWS/EFS", "PercentIOLimit",
          "FileSystemId", "${EFS_ID}",
          { "stat": "Average", "label": "Limite de I/O (%)" }
        ]],
        "annotations": { "horizontal": [{ "value": 80, "label": "Alerta", "color": "#d62728" }] },
        "region": "${AWS_REGION}"
      }
    },

    {
      "type": "text",
      "x": 0, "y": 22, "width": 24, "height": 1,
      "properties": {
        "markdown": "### Camada 3 — Banco de dados relacional (RDS MySQL)"
      }
    },

    {
      "type": "metric",
      "x": 0, "y": 23, "width": 8, "height": 6,
      "properties": {
        "title": "CPU % do RDS MySQL",
        "view": "timeSeries",
        "stacked": false,
        "metrics": [[
          "AWS/RDS", "CPUUtilization",
          "DBInstanceIdentifier", "${RDS_IDENTIFIER}",
          { "stat": "Average", "label": "CPU MySQL", "color": "#17becf" }
        ]],
        "annotations": { "horizontal": [{ "value": 85, "label": "Alerta", "color": "#d62728" }] },
        "region": "${AWS_REGION}"
      }
    },

    {
      "type": "metric",
      "x": 8, "y": 23, "width": 8, "height": 6,
      "properties": {
        "title": "Espaço Livre no RDS (bytes)",
        "view": "timeSeries",
        "stacked": false,
        "metrics": [[
          "AWS/RDS", "FreeStorageSpace",
          "DBInstanceIdentifier", "${RDS_IDENTIFIER}",
          { "stat": "Average", "label": "Disco Livre" }
        ]],
        "annotations": { "horizontal": [{ "value": 2147483648, "label": "Alerta (< 2 GB)", "color": "#d62728" }] },
        "region": "${AWS_REGION}"
      }
    },

    {
      "type": "metric",
      "x": 16, "y": 23, "width": 8, "height": 6,
      "properties": {
        "title": "Conexões e IOPS do RDS",
        "view": "timeSeries",
        "stacked": false,
        "metrics": [
          [ "AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", "${RDS_IDENTIFIER}", { "stat": "Average", "label": "Conexões",  "color": "#1f77b4" } ],
          [ "AWS/RDS", "ReadIOPS",            "DBInstanceIdentifier", "${RDS_IDENTIFIER}", { "stat": "Average", "label": "Read IOPS", "color": "#2ca02c" } ],
          [ "AWS/RDS", "WriteIOPS",           "DBInstanceIdentifier", "${RDS_IDENTIFIER}", { "stat": "Average", "label": "Write IOPS","color": "#ff7f0e" } ]
        ],
        "region": "${AWS_REGION}"
      }
    }

  ]
}
EOF
)

aws cloudwatch put-dashboard \
    --dashboard-name "${PROJECT_NAME}-dashboard" \
    --dashboard-body "$DASHBOARD_BODY" \
    --region "$AWS_REGION"

log_ok "Dashboard criado: ${PROJECT_NAME}-dashboard"

# ================================================================
#  4. RESUMO FINAL
# ================================================================

log_section "4/4 — Resumo"

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║      MONITORAMENTO CONFIGURADO COM SUCESSO!          ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BLUE}  ALARMES CRIADOS${NC}"
echo    "  ├─ ec2-down-frontend-1a       (StatusCheckFailed)"
echo    "  ├─ ec2-down-frontend-2b       (StatusCheckFailed)"
echo    "  ├─ ec2-down-backend-1a        (StatusCheckFailed)"
echo    "  ├─ ec2-down-backend-1b        (StatusCheckFailed)"
echo    "  ├─ ec2-down-bastion           (StatusCheckFailed)"
echo    "  ├─ backend-cpu-alta-1a        (CPUUtilization > 80%)"
echo    "  ├─ backend-cpu-alta-1b        (CPUUtilization > 80%)"
echo    "  ├─ alb-high-5xx-errors        (5XX Count ≥ 5 em 1 min)"
echo    "  ├─ rds-high-cpu               (CPU > 85% por 5 min)"
echo    "  └─ rds-disco-critico          (FreeStorageSpace ≤ 2 GB)"
echo ""
echo -e "${BLUE}  DASHBOARD${NC}"
echo    "  └─ ${PROJECT_NAME}-dashboard"
echo    "     https://console.aws.amazon.com/cloudwatch/home?region=${AWS_REGION}#dashboards:name=${PROJECT_NAME}-dashboard"
echo ""
echo -e "${BLUE}  SNS TOPIC${NC}"
echo    "  └─ $SNS_TOPIC_ARN"
echo ""
echo -e "${YELLOW}  ATENÇÃO — ETAPAS MANUAIS NECESSÁRIAS:${NC}"
echo    "  1. Confirme a inscrição do e-mail no SNS topic para receber alertas."
echo    "  2. Instale o CloudWatch Agent nas instâncias EC2 (veja o bloco"
echo    "     PRÉ-REQUISITO no início deste script) para ativar as métricas"
echo    "     de RAM (mem_used_percent) exibidas no dashboard."
echo    "  3. Adicione a subscrição de e-mail ao tópico SNS:"
echo    "     aws sns subscribe --topic-arn '${SNS_TOPIC_ARN}' \\"
echo    "       --protocol email --notification-endpoint SEU@EMAIL.COM \\"
echo    "       --region ${AWS_REGION}"
echo ""
