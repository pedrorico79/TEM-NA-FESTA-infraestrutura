#!/usr/bin/env bash
# Pré-checagens do infra antes de plan, up, down e bootstrap (04, seção 3;
# 08, seções 5.3 e 5.4). Nada aqui roda sozinho: toda ação sobre o state
# pede a sua confirmação.
#
# Uso: scripts/preflight.sh <plan|up|down|bootstrap> [env] [--yes]
#
# Ordem: ambiente válido; credenciais; tempo de sessão (up, down, bootstrap);
# errored.tfstate; lock órfão; manager_count com o ambiente no ar (só up).
# Saída: 0 pode seguir; 2 pré-condição não atendida (com o que fazer);
# 1 erro inesperado.
set -euo pipefail

INFRA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=scripts/lib/common.sh
source "$INFRA_ROOT/scripts/lib/common.sh"

LOCK_RECENT_MIN=10

usage() { sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# --- 1. ambiente e credenciais -------------------------------------------------------

check_env() {
  case "$ENV_NAME" in
    dev | prod) ;;
    "") die "$EXIT_PRECONDITION" "informe o ambiente: dev ou prod (por exemplo, infra $OP dev)." ;;
    *) die "$EXIT_PRECONDITION" "ambiente '$ENV_NAME' desconhecido: apenas dev ou prod (03, T1)." ;;
  esac
}

check_credentials() {
  command -v aws >/dev/null 2>&1 || die "$EXIT_PRECONDITION" "aws não encontrado. Rode 'infra doctor'."
  command -v jq >/dev/null 2>&1 || die "$EXIT_PRECONDITION" "jq não encontrado. Rode 'infra doctor'."
  if ! ACCOUNT_ID="$(timeout 30 aws sts get-caller-identity --query Account --output text 2>/dev/null)" || [[ -z "$ACCOUNT_ID" ]]; then
    die "$EXIT_PRECONDITION" "credenciais da AWS ausentes, inválidas ou vencidas. No Learner Lab, clique em Start Lab e em AWS Details, e cole o bloco [default] em ~/.aws/credentials dentro do WSL (docs/primeiros-passos-windows.md, passo 4). Nada foi feito."
  fi
}

# --- 2. estado limpo (08, seção 5.3) -------------------------------------------------

# tf_init: init da raiz com o backend no bucket de state.
tf_init() {
  terraform -chdir="$TF_DIR" init -input=false -reconfigure \
    -backend-config="bucket=$STATE_BUCKET" -backend-config="region=$STATE_REGION" >/dev/null
}

check_errored() {
  local errored="$TF_DIR/errored.tfstate"
  [[ -f "$errored" ]] || return 0

  local local_serial remote_serial remote
  local_serial="$(jq -r '.serial // 0' "$errored")"
  say_warn "existe $errored: numa execução anterior o Terraform não conseguiu gravar o state remoto (provavelmente as credenciais venceram). Os recursos criados continuam na AWS."
  tf_init || die "$EXIT_PRECONDITION" "não foi possível acessar o state remoto. Renove as credenciais do laboratório e rode de novo; $errored foi preservado."
  remote="$(terraform -chdir="$TF_DIR" state pull 2>/dev/null || true)"
  remote_serial=0
  if [[ -n "$remote" ]]; then
    remote_serial="$(jq -r '.serial // 0' <<<"$remote" 2>/dev/null || echo 0)"
  fi
  echo "versão (serial) do arquivo local: $local_serial; do state remoto: $remote_serial"
  if ((remote_serial > local_serial)); then
    die "$EXIT_PRECONDITION" "o state remoto é mais novo que $errored, então o infra não o envia (nunca usa -force). Decida manualmente: compare os dois com 'terraform state pull' e o arquivo, que foi preservado em $errored."
  fi
  if ! confirm "Enviar $errored ao state remoto com 'terraform state push'?"; then
    die "$EXIT_PRECONDITION" "nada foi enviado; $errored foi preservado. Rode de novo quando quiser recuperar o state."
  fi
  terraform -chdir="$TF_DIR" state push errored.tfstate
  local dest
  dest="$INFRA_ROOT/.infra/recovered/$STATE_NAME-$(date -u +%Y%m%d-%H%M%S).tfstate"
  mkdir -p "$(dirname "$dest")"
  mv "$errored" "$dest"
  say_ok "state enviado; a cópia local foi arquivada em ${dest#"$INFRA_ROOT"/}."
  echo "O que ainda falta aplicar:"
  terraform -chdir="$TF_DIR" plan -input=false || true
}

check_lock() {
  local lock
  if ! lock="$(aws s3 cp "s3://$STATE_BUCKET/$STATE_KEY.tflock" - 2>/dev/null)" || [[ -z "$lock" ]]; then
    return 0
  fi
  local id who op created created_s age_min host
  id="$(jq -r '.ID // "?"' <<<"$lock")"
  who="$(jq -r '.Who // "?"' <<<"$lock")"
  op="$(jq -r '.Operation // "?"' <<<"$lock")"
  created="$(jq -r '.Created // ""' <<<"$lock")"
  age_min="?"
  if [[ -n "$created" ]] && created_s="$(date -d "$created" +%s 2>/dev/null)"; then
    age_min="$((($(date +%s) - created_s) / 60))"
  fi
  host="$(hostname 2>/dev/null || echo "?")"

  say_warn "o state $STATE_KEY está travado por um lock:"
  echo "  quem:     $who"
  echo "  quando:   $created (há $age_min minuto(s))"
  echo "  operação: $op"
  echo "  ID:       $id"
  if [[ "$age_min" != "?" ]] && ((age_min < LOCK_RECENT_MIN)); then
    say_warn "ATENÇÃO: o lock foi criado há menos de $LOCK_RECENT_MIN minutos. Pode haver outra execução em andamento."
  fi
  if [[ "$who" != *"@$host" ]]; then
    say_warn "ATENÇÃO: o lock foi criado por outra máquina ($who; esta é $host)."
  fi
  echo "Existe outra execução sua em andamento (outra janela do WSL ou outra máquina)? Se existir, não destrave: espere ela terminar."
  local typed=""
  printf 'Para destravar, digite o nome do ambiente (%s); qualquer outra resposta cancela: ' "$STATE_NAME" >&2
  read -r typed || true
  if [[ "$typed" != "$STATE_NAME" ]]; then
    die "$EXIT_PRECONDITION" "nada foi destravado. Quando a outra execução terminar, ou se tiver certeza de que não há nenhuma, rode de novo."
  fi
  tf_init
  terraform -chdir="$TF_DIR" force-unlock -force "$id"
  say_ok "lock removido."
  echo "O que ainda falta aplicar:"
  terraform -chdir="$TF_DIR" plan -input=false || true
  die "$EXIT_PRECONDITION" "repita 'infra $OP${ENV_NAME:+ $ENV_NAME}' (a operação é idempotente)."
}

# --- 3. manager_count fixo com o ambiente no ar (08, seção 5.4) ----------------------

check_manager_count() {
  local tfvars="$INFRA_ROOT/envs/$ENV_NAME/terraform.tfvars"
  local region bucket applied wanted stack_env
  region="$(read_tfvar "$tfvars" region us-east-1)"
  bucket="tnf-$ENV_NAME-artifacts-$ACCOUNT_ID-$region"
  if ! stack_env="$(aws s3 cp "s3://$bucket/stack.env" - 2>/dev/null)" || [[ -z "$stack_env" ]]; then
    return 0 # ambiente novo: não há o que comparar
  fi
  applied="$(sed -n -E 's/^MANAGER_COUNT=([0-9]+).*/\1/p' <<<"$stack_env" | tail -n 1)"
  [[ -n "$applied" ]] || return 0
  wanted="$(read_tfvar "$tfvars" manager_count 1)"
  if [[ "$applied" != "$wanted" ]]; then
    die "$EXIT_PRECONDITION" "manager_count em vigor no ambiente $ENV_NAME é $applied, e o terraform.tfvars pede $wanted. O número de managers é o quórum do Swarm e fica fixo durante a vida do ambiente (03, seção 3.2). Para mudar o número de managers, recrie o ambiente: infra down $ENV_NAME e infra up $ENV_NAME. Nada foi aplicado."
  fi
}

# --- principal -----------------------------------------------------------------------

main() {
  OP="${1:-}"
  ENV_NAME=""
  [[ $# -gt 0 ]] && shift
  local arg
  for arg in "$@"; do
    case "$arg" in
      --yes) ;; # aceito, mas não pula o aviso de sessão (08, seção 5.3)
      -*) die "$EXIT_PRECONDITION" "opção desconhecida: $arg" ;;
      *) ENV_NAME="$arg" ;;
    esac
  done
  case "$OP" in
    -h | --help) usage; exit 0 ;;
    plan | up | down) check_env ;;
    bootstrap) ENV_NAME="" ;;
    *) die "$EXIT_PRECONDITION" "uso: scripts/preflight.sh <plan|up|down|bootstrap> [env]" ;;
  esac

  check_credentials
  case "$OP" in
    up | down | bootstrap) session_guard ;;
  esac

  STATE_REGION="$(read_tfvar "$INFRA_ROOT/bootstrap/terraform.tfvars" region us-east-1)"
  STATE_BUCKET="tnf-tfstate-$ACCOUNT_ID-$STATE_REGION"
  if [[ "$OP" == bootstrap ]]; then
    TF_DIR="$INFRA_ROOT/bootstrap" STATE_KEY="bootstrap/terraform.tfstate" STATE_NAME="bootstrap"
    # Antes da primeira criação o bucket de state não existe: não há lock nem state remoto.
    aws s3api head-bucket --bucket "$STATE_BUCKET" >/dev/null 2>&1 || return 0
  else
    TF_DIR="$INFRA_ROOT/envs/$ENV_NAME" STATE_KEY="envs/$ENV_NAME/terraform.tfstate" STATE_NAME="$ENV_NAME"
    if ! aws s3api head-bucket --bucket "$STATE_BUCKET" >/dev/null 2>&1; then
      die "$EXIT_PRECONDITION" "o bucket de state $STATE_BUCKET não existe ou não está acessível. Rode 'infra bootstrap' uma vez nesta conta."
    fi
  fi

  check_errored
  check_lock
  if [[ "$OP" == up ]]; then
    check_manager_count
  fi
}

main "$@"
