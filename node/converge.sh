#!/usr/bin/env bash
# Convergência do ambiente (04, seção 7), executada a cada 60 s pelo
# tnf-converge.timer em todos os managers; só age no líder atual do Swarm.
# Até a E4b de 09: espera do READY e download dos arquivos (passo 3), nós
# esperados e limpeza (passo 1), rótulos (passo 2), inicialização do banco
# (passo 6, tnf-db-init) e status (passo 9). Rede, segredos e stacks chegam
# na E6.
set -euo pipefail

# shellcheck source=/dev/null
source /etc/tnf-node.env
S3="s3://$TNF_ARTIFACTS_BUCKET"
WORK=/var/lib/tnf
EXPECTED_WAIT_MAX=1200 # 20 min para os nós esperados ficarem Ready (04, seção 7, passo 1)
LOG=/var/log/tnf-converge.log
mkdir -p "$WORK"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG"; }

is_leader() {
  [[ "$(docker node inspect self --format '{{.ManagerStatus.Leader}}' 2>/dev/null)" == true ]]
}

# write_status <state> <mensagem> <faltando> <sem_rotulo> <removidos>
write_status() {
  jq -n --arg state "$1" --arg message "$2" --arg time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg manifest "${MANIFEST_HASH:-}" --arg leader "$(hostname)" \
    --arg missing "$3" --arg unlabeled "$4" --arg removed "$5" \
    '{state: $state, message: $message, time: $time, manifest_hash: $manifest, leader: $leader,
      missing_nodes: ($missing | split(" ") | map(select(. != ""))),
      unlabeled_nodes: ($unlabeled | split(" ") | map(select(. != ""))),
      removed_nodes: ($removed | split(" ") | map(select(. != ""))),
      services: {}}' |
    aws s3 cp - "$S3/status/converge.json" --region "$TNF_REGION" --only-show-errors
}

# --- passo 3: READY e arquivos -------------------------------------------------------

fetch_artifacts() {
  if ! aws s3api head-object --bucket "$TNF_ARTIFACTS_BUCKET" --key READY --region "$TNF_REGION" >/dev/null 2>&1; then
    log "aguardando o marcador READY"
    return 1
  fi
  aws s3 cp "$S3/stack.env" "$WORK/stack.env" --region "$TNF_REGION" --only-show-errors
  aws s3 cp "$S3/manifest.json" "$WORK/manifest.json" --region "$TNF_REGION" --only-show-errors
  MANIFEST_HASH="$(jq -r .hash "$WORK/manifest.json")"
  EXPECTED_NODES="$(sed -n 's/^EXPECTED_NODES=//p' "$WORK/stack.env" | tr ',' ' ')"
}

# --- passo 1: nós esperados e limpeza --------------------------------------------------

# node_table: "<hostname> <Ready|Down|...> <manager?>" de cada nó do Swarm.
node_table() {
  docker node ls --format '{{.Hostname}} {{.Status}} {{if .ManagerStatus}}manager{{else}}worker{{end}}'
}

check_expected_nodes() {
  local table host missing="" since now
  table="$(node_table)"
  for host in $EXPECTED_NODES; do
    grep -q "^$host Ready " <<<"$table" || missing="$missing $host"
  done
  MISSING="${missing# }"

  # Prazo de 20 min contado desde que esta lista de nós passou a ser esperada.
  now="$(date +%s)"
  if [[ "$(cat "$WORK/expected.list" 2>/dev/null)" != "$EXPECTED_NODES" ]]; then
    printf '%s' "$EXPECTED_NODES" >"$WORK/expected.list"
    printf '%s' "$now" >"$WORK/expected.since"
  fi
  since="$(cat "$WORK/expected.since")"
  WAIT_EXPIRED=false
  if [[ -n "$MISSING" ]] && ((now - since > EXPECTED_WAIT_MAX)); then
    WAIT_EXPIRED=true
  fi

  # Limpeza: nós Down fora da lista são removidos; managers nunca.
  REMOVED="" MANAGER_OUT=""
  local name state kind
  while read -r name state kind; do
    [[ -n "$name" ]] || continue
    [[ " $EXPECTED_NODES " == *" $name "* ]] && continue
    [[ "$state" == Down ]] || continue
    if [[ "$kind" == manager ]]; then
      MANAGER_OUT="$MANAGER_OUT $name"
      continue
    fi
    log "removendo do Swarm o nó $name (Down e fora de EXPECTED_NODES)"
    docker node rm "$name" >/dev/null && REMOVED="$REMOVED $name"
  done <<<"$table"
}

# --- passo 2: rótulos pelo final do hostname (D22) ------------------------------------

apply_labels() {
  UNLABELED=""
  local host
  while read -r host; do
    [[ -n "$host" ]] || continue
    if [[ "$host" =~ -(web|app)-([0-9]+)$ ]]; then
      local tier="${BASH_REMATCH[1]}" n="${BASH_REMATCH[2]}"
      docker node update --label-add "tier=$tier" "$host" >/dev/null
      if [[ "$tier" == app && "$n" == 1 ]]; then
        docker node update --label-add rabbitmq=true --label-add messaging=true "$host" >/dev/null
      fi
    else
      UNLABELED="$UNLABELED $host"
    fi
  done < <(docker node ls --format '{{.Hostname}}')
}

# --- principal ---------------------------------------------------------------------

main() {
  if ! is_leader; then
    exit 0
  fi
  if ! fetch_artifacts; then
    write_status waiting "aguardando o marcador READY no bucket de artefatos" "" "" ""
    exit 0
  fi
  check_expected_nodes
  apply_labels

  # Passo 6: banco (04, seção 7; 05, B5). Saída: ok, waiting <msg> ou failed <msg>.
  local db
  db="$(/usr/local/sbin/tnf-db-init "$WORK/stack.env" "$MANIFEST_HASH" 2>>"$LOG")" ||
    db="failed o db-init terminou com erro inesperado; veja /var/log/tnf-db-init.log no líder"
  DB_STATE="${db%% *}"
  DB_MSG="${db#* }"
  [[ "$DB_STATE" == ok ]] && DB_MSG=""

  local state=ready msg="todos os nós esperados estão Ready e rotulados, e o banco está inicializado"
  if [[ -n "${MANAGER_OUT// /}" ]]; then
    state=degraded
    msg="nó(s) manager Down fora de EXPECTED_NODES:${MANAGER_OUT}; o líder nunca remove um manager. Recrie o ambiente (infra down e infra up)."
  elif [[ -n "${UNLABELED// /}" ]]; then
    state=degraded
    msg="nó(s) do Swarm sem rótulo, porque o hostname não termina em -web-<n> nem -app-<n>:${UNLABELED}. O formato do nome é contrato entre o Terraform e o converge.sh (03, seção 5)."
  elif [[ "$DB_STATE" == failed ]]; then
    state=degraded
    msg="banco: $DB_MSG"
  elif [[ -n "$MISSING" && "$WAIT_EXPIRED" == true ]]; then
    state=degraded
    msg="nós esperados ausentes ou Down depois de 20 minutos: $MISSING. Não há autorrecuperação: recrie o ambiente (infra down e infra up)."
  elif [[ -n "$MISSING" ]]; then
    state=waiting
    msg="aguardando os nós esperados: $MISSING"
  elif [[ "$DB_STATE" == waiting ]]; then
    state=waiting
    msg="banco: $DB_MSG"
  fi
  write_status "$state" "$msg" "$MISSING" "${UNLABELED# }" "${REMOVED# }"
  log "converge: $state ($msg)"
}

main "$@"
