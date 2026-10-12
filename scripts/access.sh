#!/usr/bin/env bash
# Acesso SSH a partir desta máquina e desta rede (08, seção 5.6; 02, A15).
#
# Uso: scripts/access.sh <env> [--ip <ip>] [--ssh]
#   Chave: recria .keys/<env>.pem a partir do state quando falta ou não
#          corresponde ao ambiente (sem perguntar; nunca em /mnt/c).
#   IP:    detecta o IP público atual (ou usa --ip) e, se ele não estiver
#          autorizado no bastion, pergunta s/N e aplica só a regra do SSH.
#   --ssh: modo usado pelo infra ssh; com N, termina com código 2 dizendo
#          para rodar infra access <env>.
# Saída: 0 acesso pronto; 2 pré-condição não atendida ou cancelado; 1 erro.
set -euo pipefail

INFRA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=scripts/lib/common.sh
source "$INFRA_ROOT/scripts/lib/common.sh"

usage() { sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

ENV_NAME="" IP_ARG="" SSH_MODE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --ip) IP_ARG="${2:-}"; shift 2 ;;
    --ssh) SSH_MODE=1; shift ;;
    -*) die "$EXIT_PRECONDITION" "opção desconhecida: $1" ;;
    *) ENV_NAME="$1"; shift ;;
  esac
done
case "$ENV_NAME" in
  dev | prod) ;;
  *) die "$EXIT_PRECONDITION" "informe o ambiente: dev ou prod (03, T1)." ;;
esac

TF_DIR="$(env_tf_dir "$ENV_NAME")"
TF_DATA_DIR="$(env_tf_data_dir "$ENV_NAME")"
export TF_DATA_DIR
TFVARS="$INFRA_ROOT/envs/$ENV_NAME/terraform.tfvars"
KEY_DIR="$INFRA_ROOT/.keys"
KEY_FILE="$KEY_DIR/$ENV_NAME.pem"

tf() { terraform -chdir="$TF_DIR" "$@"; }

# --- state ---------------------------------------------------------------------------

open_state() {
  command -v aws >/dev/null 2>&1 || die "$EXIT_PRECONDITION" "aws não encontrado. Rode 'infra doctor'."
  local account state_region
  account="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" ||
    die "$EXIT_PRECONDITION" "credenciais da AWS ausentes, inválidas ou vencidas. Renove as credenciais do laboratório dentro do WSL (docs/primeiros-passos-windows.md, passo 4)."
  state_region="$(read_tfvar "$INFRA_ROOT/bootstrap/terraform.tfvars" region us-east-1)"
  tf init -input=false -reconfigure \
    -backend-config="bucket=tnf-tfstate-$account-$state_region" \
    -backend-config="region=$state_region" \
    -backend-config="key=$(env_state_key "$ENV_NAME")" >/dev/null 2>&1 ||
    die "$EXIT_PRECONDITION" "não foi possível abrir o state do ambiente $ENV_NAME. Confira as credenciais e se o bootstrap foi feito."
  if ! PUBLIC_KEY="$(tf output -raw ssh_public_key 2>/dev/null)" || [[ -z "$PUBLIC_KEY" ]]; then
    die "$EXIT_PRECONDITION" "o ambiente $ENV_NAME não está no ar (não há chave no state). Rode 'infra up $ENV_NAME'."
  fi
}

# --- chave ---------------------------------------------------------------------------

write_key() {
  (
    umask 077
    mkdir -p "$KEY_DIR"
    tf output -raw ssh_private_key >"$KEY_FILE.tmp"
    printf '\n' >>"$KEY_FILE.tmp"
    chmod 600 "$KEY_FILE.tmp"
    mv "$KEY_FILE.tmp" "$KEY_FILE"
  )
}

ensure_key() {
  if is_windows_mount "$INFRA_ROOT"; then
    die "$EXIT_PRECONDITION" "o repositório está em $INFRA_ROOT, no disco do Windows: o infra não grava a chave SSH ali, porque a permissão 600 não funciona em /mnt/c (08, seção 5.1). Clone-o dentro do WSL, por exemplo em ~/projetos."
  fi
  if [[ ! -f "$KEY_FILE" ]]; then
    write_key
    say_ok "chave SSH recriada a partir do state em .keys/$ENV_NAME.pem (permissão 600)."
    return 0
  fi
  local current
  current="$(ssh-keygen -y -f "$KEY_FILE" 2>/dev/null | awk '{print $1" "$2}')" || current=""
  if [[ "$current" == "$(awk '{print $1" "$2}' <<<"$PUBLIC_KEY")" ]]; then
    return 0
  fi
  mv "$KEY_FILE" "$KEY_FILE.anterior"
  write_key
  say_warn "a chave .keys/$ENV_NAME.pem era de outro ambiente com o mesmo nome; foi trocada pela atual, e a antiga ficou em .keys/$ENV_NAME.pem.anterior."
}

# --- IP ------------------------------------------------------------------------------

# ip_to_int <a.b.c.d>
ip_to_int() {
  local IFS=. a b c d
  read -r a b c d <<<"$1"
  printf '%s' "$(((a << 24) + (b << 16) + (c << 8) + d))"
}

# cidr_covers <cidr> <ip>
cidr_covers() {
  local net="${1%/*}" bits="${1#*/}" mask
  [[ "$1" == */* ]] || bits=32
  ((bits == 0)) && return 0
  mask=$(((0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF))
  local n i
  n="$(ip_to_int "$net")"
  i="$(ip_to_int "$2")"
  (((n & mask) == (i & mask)))
}

valid_ipv4() {
  [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  local o
  for o in "${BASH_REMATCH[@]:1}"; do ((o <= 255)) || return 1; done
}

detect_ip() {
  if [[ -n "$IP_ARG" ]]; then
    if [[ "$IP_ARG" == */* ]] || ! valid_ipv4 "$IP_ARG" || [[ "$IP_ARG" == 0.0.0.0 ]]; then
      die "$EXIT_PRECONDITION" "--ip aceita um único endereço IPv4 (por exemplo 203.0.113.10), que vira /32. Faixas e 0.0.0.0/0 são recusadas: SSH aberto para o mundo é proibido (03, T9)."
    fi
    MY_IP="$IP_ARG"
    return 0
  fi
  MY_IP="$(curl -fsS --max-time 10 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]')" || MY_IP=""
  if ! valid_ipv4 "$MY_IP"; then
    die "$EXIT_PRECONDITION" "não foi possível detectar o seu IP público. Informe-o com --ip <ip> (por exemplo, o que aparece em https://checkip.amazonaws.com)."
  fi
}

# authorized_cidrs: CIDRs com a porta 22 liberada no security group do bastion.
authorized_cidrs() {
  local sg
  sg="$(tf output -raw bastion_security_group_id)"
  aws ec2 describe-security-group-rules --filters "Name=group-id,Values=$sg" --output json |
    jq -r '.SecurityGroupRules[] | select(.IsEgress == false and .FromPort <= 22 and .ToPort >= 22) | .CidrIpv4 // empty'
}

tfvars_cidrs() {
  sed -n -E 's/^[[:space:]]*admin_ssh_cidrs[[:space:]]*=[[:space:]]*\[(.*)\].*/\1/p' "$TFVARS" | tr -d '" ' | tr ',' '\n' | sed '/^$/d'
}

covered_by() {
  local c
  while read -r c; do
    [[ -n "$c" ]] || continue
    cidr_covers "$c" "$MY_IP" && return 0
  done <<<"$1"
  return 1
}

authorize_ip() {
  local mine fixed current
  fixed="$(tfvars_cidrs)"
  if [[ -n "$fixed" ]]; then
    if ! covered_by "$fixed"; then
      say_warn "admin_ssh_cidrs está preenchida em envs/$ENV_NAME/terraform.tfvars e não cobre o seu IP atual ($MY_IP). O infra não altera essa lista: acrescente \"$MY_IP/32\" a ela e rode 'infra up $ENV_NAME' (03, seção 3.6)."
    fi
    return 0
  fi

  current="$(authorized_cidrs)"
  if covered_by "$current"; then
    say_ok "o seu IP atual ($MY_IP) já está autorizado no bastion."
    return 0
  fi
  echo "autorizado no bastion: ${current//$'\n'/ }"
  echo "seu IP atual: $MY_IP"
  if ! confirm "Autorizar $MY_IP/32 no bastion (substitui o anterior)?"; then
    if [[ "$SSH_MODE" -eq 1 ]]; then
      die "$EXIT_PRECONDITION" "o seu IP não está autorizado no bastion, e a conexão expiraria. Para autorizar, rode 'infra access $ENV_NAME'."
    fi
    die "$EXIT_PRECONDITION" "nada foi alterado."
  fi

  "$INFRA_ROOT/scripts/preflight.sh" plan "$ENV_NAME"
  mine="[\"$MY_IP/32\"]"
  local plan="$INFRA_ROOT/.infra/access-$ENV_NAME.tfplan"
  mkdir -p "$(dirname "$plan")"
  tf plan -input=false -var-file="$TFVARS" -var="admin_ssh_cidrs=$mine" -compact-warnings -out="$plan" >/dev/null
  local others
  others="$(tf show -json "$plan" | jq -r '
    [.resource_changes[]
      | select(.change.actions != ["no-op"])
      | select(.address | test("module\\.security\\.aws_vpc_security_group_ingress_rule\\.bastion_ssh\\[") | not)
      | .address] | .[]')"
  if [[ -n "$others" ]]; then
    rm -f "$plan"
    die "$EXIT_PRECONDITION" "há outras mudanças pendentes no ambiente além da regra do SSH ($(tr '\n' ' ' <<<"$others")); nada foi aplicado. Rode 'infra up $ENV_NAME'."
  fi
  tf apply -input=false "$plan"
  rm -f "$plan"
  say_ok "o bastion agora aceita SSH de $MY_IP/32."
}

main() {
  open_state
  ensure_key
  detect_ip
  authorize_ip
}

main
