#!/usr/bin/env bash
# Acompanha a subida do ambiente pelo bucket de artefatos (04, seção 8).
#
# Uso: scripts/wait-ready.sh <env> <bucket> <região> <nós> [bastion] [--once]
#   <nós>     hostnames do Swarm separados por vírgula (devem chegar a joined)
#   [bastion] hostname do bastion (deve chegar a ready); "-" se não houver
#   --once    só mostra a situação atual e sai (usado pelo infra status)
# Espera até 25 minutos: cada nó em joined (bastion em ready) e
# status/converge.json em ready. Um nó em failed, ou o converge.json em
# degraded, encerra a espera na hora com a mensagem.
# Saída: 0 pronto; 3 tempo esgotado ou ambiente no ar mas não pronto.
set -euo pipefail

INFRA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=scripts/lib/common.sh
source "$INFRA_ROOT/scripts/lib/common.sh"

ENV_NAME="${1:?ambiente}" BUCKET="${2:?bucket}" REGION="${3:?região}" NODES="${4:?nós}"
BASTION="${5:--}"
ONCE=0
[[ "${6:-}" == --once || "${5:-}" == --once ]] && ONCE=1
[[ "$BASTION" == --once ]] && BASTION="-"
TIMEOUT="${TNF_WAIT_TIMEOUT:-1500}" # 25 min (04, seção 8)
INTERVAL="${TNF_WAIT_INTERVAL:-15}"
SILENT_MAX="${TNF_WAIT_SILENT:-900}" # 15 min sem nenhum status do nó = falha (04, S6)

s3_json() { aws s3 cp "s3://$BUCKET/$1" - --region "$REGION" 2>/dev/null || true; }

# jget <json> <filtro> <padrão>: campo do JSON, ou o padrão se o JSON estiver vazio.
jget() {
  local v=""
  [[ -n "$1" ]] && v="$(jq -r "$2 // empty" <<<"$1" 2>/dev/null || true)"
  printf '%s' "${v:-$3}"
}

# check: imprime a situação e define READY_ALL, FAILED_MSG e CONVERGE_STATE.
check() {
  READY_ALL=1 FAILED_MSG=""
  local host want doc state step msg
  for host in ${NODES//,/ } ${BASTION/#-/}; do
    want=joined
    [[ "$host" == "$BASTION" ]] && want=ready
    doc="$(s3_json "status/nodes/$host.json")"
    state="$(jget "$doc" .state aguardando)"
    step="$(jget "$doc" .step "")"
    msg="$(jget "$doc" .message "")"
    printf '  %-32s %-11s %s\n' "$host" "$state" "${step:+($step) }$msg"
    if [[ "$state" == failed ]]; then
      FAILED_MSG="o nó $host falhou na etapa $step: $msg. Veja /var/log/tnf-bootstrap.log no nó (infra ssh $ENV_NAME ${host##*-"$ENV_NAME"-})."
    elif [[ -z "$doc" && "$ONCE" -eq 0 ]] && (($(date +%s) - start >= SILENT_MAX)); then
      # Sem nenhum status: o nó não conseguiu nem instalar o AWS CLI, em geral
      # porque não tem saída para a internet (rota da NAT; 04, S6).
      FAILED_MSG="o nó $host não deu nenhum sinal em $((SILENT_MAX / 60)) minutos: provavelmente não tem saída para a internet (confira a rota da NAT da subnet dele) e não conseguiu instalar o AWS CLI. Veja /var/log/tnf-bootstrap.log no nó."
    fi
    [[ "$state" == "$want" ]] || READY_ALL=0
  done
  doc="$(s3_json status/converge.json)"
  CONVERGE_STATE="$(jget "$doc" .state aguardando)"
  CONVERGE_MSG="$(jget "$doc" .message "")"
  printf '  %-32s %-11s %s\n' "convergência" "$CONVERGE_STATE" "$CONVERGE_MSG"
  # Serviços (04, seção 7, passo 9): situação, réplicas e imagem em execução.
  if [[ -n "$doc" ]]; then
    jq -r '(.services // {}) | to_entries[] |
      "  \("serviço " + .key | .[0:32] | . + " " * (32 - length)) \(.value.state | . + " " * (11 - length)) \(if .value.state == "off" then "desligado" else "\(.value.running)/\(.value.desired) \(.value.image)" end)"' \
      <<<"$doc" 2>/dev/null || true
  fi
  [[ "$CONVERGE_STATE" == ready ]] || READY_ALL=0
}

start="$(date +%s)"
while :; do
  echo "== situação do ambiente $ENV_NAME ($(date +%H:%M:%S))"
  check
  if [[ "$READY_ALL" -eq 1 ]]; then
    say_ok "ambiente $ENV_NAME pronto."
    exit "$EXIT_OK"
  fi
  if [[ -n "$FAILED_MSG" ]]; then
    die "$EXIT_TIMEOUT" "$FAILED_MSG"
  fi
  if [[ "$CONVERGE_STATE" == degraded ]]; then
    die "$EXIT_TIMEOUT" "o ambiente está no ar, mas degradado: $CONVERGE_MSG"
  fi
  if [[ "$ONCE" -eq 1 ]]; then
    exit "$EXIT_TIMEOUT"
  fi
  if (($(date +%s) - start >= TIMEOUT)); then
    die "$EXIT_TIMEOUT" "o ambiente não ficou pronto em $((TIMEOUT / 60)) minutos. Veja acima qual nó ou etapa não chegou ao fim e confira /var/log/tnf-bootstrap.log no nó."
  fi
  sleep "$INTERVAL"
done
