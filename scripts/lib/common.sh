#!/usr/bin/env bash
# Funções comuns do infra e dos scripts de apoio (08, seções 2 e 4.3).
# Uso: source "scripts/lib/common.sh". Não imprime segredos.

# Códigos de saída (08, seção 4.3).
readonly EXIT_OK=0
readonly EXIT_UNEXPECTED=1
readonly EXIT_PRECONDITION=2
readonly EXIT_TIMEOUT=3
export EXIT_OK EXIT_UNEXPECTED EXIT_PRECONDITION EXIT_TIMEOUT

# Linhas de resultado padronizadas.
say_ok()   { printf '[ok]    %s\n' "$*"; }
say_warn() { printf '[aviso] %s\n' "$*"; }
say_miss() { printf '[falta] %s\n' "$*"; }
say_info() { printf '[info]  %s\n' "$*"; }

# die <código> <mensagem>: termina com a mensagem do que aconteceu e do que fazer.
die() {
  local code="$1"; shift
  printf 'ERRO: %s\n' "$*" >&2
  exit "$code"
}

# is_windows_mount <caminho>: verdadeiro se o caminho está no disco do Windows
# montado pelo WSL (/mnt/<letra>/...), onde permissões 600 não funcionam (5.1).
is_windows_mount() {
  case "$1" in
    /mnt/[a-zA-Z] | /mnt/[a-zA-Z]/*) return 0 ;;
    *) return 1 ;;
  esac
}

# is_wsl: verdadeiro se está rodando dentro do WSL.
is_wsl() {
  uname -r 2>/dev/null | grep -qi microsoft
}

# version_ge <versão> <mínima>: verdadeiro se versão >= mínima (formato x.y.z).
version_ge() {
  local IFS=.
  local -a a b
  read -r -a a <<<"$1"
  read -r -a b <<<"$2"
  local i
  for i in 0 1 2; do
    local x="${a[i]:-0}" y="${b[i]:-0}"
    x="${x%%[!0-9]*}"; y="${y%%[!0-9]*}"
    x="${x:-0}"; y="${y:-0}"
    if ((10#$x > 10#$y)); then return 0; fi
    if ((10#$x < 10#$y)); then return 1; fi
  done
  return 0
}

# --- Sobras da infraestrutura antiga (08, seção 5.2; G17) ------------------------
# list_leftovers: imprime, um por linha, "<tipo> <id> <nome>" dos recursos da
# região atual SEM as etiquetas ManagedBy = terraform e Project = tem-na-festa.
# Só lê; nunca apaga nada.

# shellcheck disable=SC2016 # é um programa do jq, não uma expansão do bash
_JQ_NOT_OURS='def ours: ((. // []) | map({(.Key): .Value}) | add // {}) as $t
  | ($t.ManagedBy == "terraform" and $t.Project == "tem-na-festa");
def name: ((. // []) | map(select(.Key == "Name")) | .[0].Value) // "-";'

list_leftovers() {
  aws ec2 describe-instances \
    --filters Name=instance-state-name,Values=pending,running,stopping,stopped \
    --output json |
    jq -r "$_JQ_NOT_OURS"' .Reservations[].Instances[] | select(.Tags | ours | not)
      | "ec2 \(.InstanceId) \(.Tags | name)"'

  aws ec2 describe-nat-gateways --filter Name=state,Values=pending,available --output json |
    jq -r "$_JQ_NOT_OURS"' .NatGateways[] | select(.Tags | ours | not)
      | "nat \(.NatGatewayId) \(.Tags | name)"'

  aws ec2 describe-addresses --output json |
    jq -r "$_JQ_NOT_OURS"' .Addresses[] | select(.Tags | ours | not)
      | "eip \(.AllocationId) \(.PublicIp)"'

  local arns
  arns="$(aws elbv2 describe-load-balancers --output json | jq -r '.LoadBalancers[].LoadBalancerArn')"
  if [[ -n "$arns" ]]; then
    # shellcheck disable=SC2086 # um ARN por palavra
    aws elbv2 describe-tags --resource-arns $arns --output json |
      jq -r "$_JQ_NOT_OURS"' .TagDescriptions[] | select(.Tags | ours | not)
        | "alb \(.ResourceArn | split("/")[-2]) \(.ResourceArn)"'
  fi

  aws rds describe-db-instances --output json |
    jq -r "$_JQ_NOT_OURS"' .DBInstances[] | select(.TagList | ours | not)
      | "rds \(.DBInstanceIdentifier) \(.DBInstanceClass)"'
}

# --- Sessão do laboratório (08, seção 5.3; G21) -------------------------------------
# A AWS não informa o vencimento das credenciais. O infra guarda em
# .infra/session.json, ligado a um resumo do token (nunca o token), quando viu
# a sessão pela primeira vez e, se você informou, quantos minutos restavam.

readonly SESSION_HOURS_MIN=240   # duração da sessão do Learner Lab (4 h)
readonly SESSION_WARN_MIN=20     # avisa com menos de 20 minutos
export SESSION_HOURS_MIN SESSION_WARN_MIN

session_file() { printf '%s/.infra/session.json' "$INFRA_ROOT"; }

# session_token_hash: resumo do token de sessão atual, ou vazio sem token.
session_token_hash() {
  local token="${AWS_SESSION_TOKEN:-}"
  if [[ -z "$token" ]]; then
    token="$(aws configure get aws_session_token 2>/dev/null || true)"
  fi
  [[ -n "$token" ]] || return 0
  printf '%s' "$token" | sha256sum | cut -c1-16
}

# session_load: lê o arquivo para a sessão atual, criando o registro na
# primeira vez que vê o token. Define SESSION_HASH, SESSION_FIRST_SEEN,
# SESSION_REPORTED_MIN e SESSION_REPORTED_AT (vazios se não houver).
session_load() {
  local now f
  now="$(date +%s)"
  f="$(session_file)"
  SESSION_HASH="$(session_token_hash)"
  SESSION_FIRST_SEEN="" SESSION_REPORTED_MIN="" SESSION_REPORTED_AT=""
  [[ -n "$SESSION_HASH" ]] || return 0
  if [[ -f "$f" ]] && [[ "$(jq -r '.token_hash // ""' "$f")" == "$SESSION_HASH" ]]; then
    SESSION_FIRST_SEEN="$(jq -r '.first_seen // ""' "$f")"
    SESSION_REPORTED_MIN="$(jq -r '.reported_minutes // ""' "$f")"
    SESSION_REPORTED_AT="$(jq -r '.reported_at // ""' "$f")"
  else
    SESSION_FIRST_SEEN="$now"
    session_save
  fi
}

session_save() {
  local f
  f="$(session_file)"
  mkdir -p "$(dirname "$f")"
  jq -n --arg h "$SESSION_HASH" --arg fs "$SESSION_FIRST_SEEN" \
    --arg rm "$SESSION_REPORTED_MIN" --arg ra "$SESSION_REPORTED_AT" \
    '{token_hash: $h, first_seen: ($fs | tonumber? // null),
      reported_minutes: ($rm | tonumber? // null), reported_at: ($ra | tonumber? // null)}' >"$f"
}

# session_remaining: imprime "<minutos> <informado|estimativa>", ou nada se as
# credenciais não têm token de sessão (fora do laboratório).
session_remaining() {
  local now
  now="$(date +%s)"
  session_load
  [[ -n "$SESSION_HASH" ]] || return 0
  if [[ -n "$SESSION_REPORTED_MIN" && -n "$SESSION_REPORTED_AT" ]]; then
    printf '%s informado\n' "$((SESSION_REPORTED_MIN - (now - SESSION_REPORTED_AT) / 60))"
  else
    printf '%s estimativa\n' "$((SESSION_HOURS_MIN - (now - SESSION_FIRST_SEEN) / 60))"
  fi
}

# confirm <pergunta>: pergunta s/N no terminal; verdadeiro só com "s".
confirm() {
  local answer=""
  printf '%s [s/N] ' "$1" >&2
  read -r answer || true
  [[ "$answer" == "s" || "$answer" == "S" ]]
}

# session_guard: antes de up, down e bootstrap. Com menos de 20 minutos (ou
# estimativa vencida), avisa e pede confirmação; --yes não pula este aviso.
session_guard() {
  local rem kind
  read -r rem kind < <(session_remaining) || true
  [[ -n "${rem:-}" ]] || return 0
  if ((rem < SESSION_WARN_MIN)); then
    if [[ "$kind" == "estimativa" ]]; then
      say_warn "pela estimativa, restam cerca de $rem minuto(s) da sessão do laboratório (a sessão pode ter começado antes). Informe o tempo real com 'infra session <minutos>'."
    else
      say_warn "restam cerca de $rem minuto(s) da sessão do laboratório. Se as credenciais vencerem no meio da operação, o state pode ficar travado (08, seção 5.3)."
    fi
    confirm "Continuar mesmo assim?" || die "$EXIT_PRECONDITION" "operação cancelada. Renove a sessão no Learner Lab, atualize as credenciais no WSL e rode de novo."
  fi
}

# --- terraform.tfvars ----------------------------------------------------------------

# read_tfvar <arquivo> <nome> <padrão>: valor simples (string ou número) de um tfvars.
read_tfvar() {
  local v
  v="$(sed -n -E "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*\"?([^\"#]*)\"?[[:space:]]*(#.*)?$/\1/p" "$1" 2>/dev/null | tail -n 1)"
  v="${v%"${v##*[![:space:]]}"}"
  printf '%s' "${v:-$3}"
}

# --- Raiz do Terraform de cada ambiente ------------------------------------------------
# A partir da E4a a raiz é envs/<env>, com o state em envs/<env>/ no bucket de
# state (08, seção 4.1; H22). Cada ambiente usa a pasta de dados .infra/tfdata/<env>.

env_tf_dir() { printf '%s/envs/%s' "$INFRA_ROOT" "$1"; }
env_state_key() { printf 'envs/%s/terraform.tfstate' "$1"; }
env_tf_data_dir() { printf '%s/.infra/tfdata/%s' "$INFRA_ROOT" "$1"; }

# env_region <env>: região do ambiente (padrão us-east-1, 03 seção 3.1).
env_region() { read_tfvar "$INFRA_ROOT/envs/$1/terraform.tfvars" region us-east-1; }

# artifacts_bucket <env> <conta> <região>: nome do bucket de artefatos (08, seção 4.2).
artifacts_bucket() { printf 'tnf-%s-artifacts-%s-%s' "$1" "$2" "$3"; }
