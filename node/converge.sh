#!/usr/bin/env bash
# Convergência do ambiente (04, seção 7), executada a cada 60 s pelo
# tnf-converge.timer em todos os managers; só age no líder atual do Swarm.
# Passos: READY e download dos arquivos (3), nós esperados e limpeza (1),
# rótulos (2), rede tnf-net (4), segredos Docker (5), banco (6, tnf-db-init),
# imagens resolvidas por digest (7), deploy das stacks na ordem rabbitmq, app
# e web (8) e status com as réplicas por serviço (9). O prazo de saúde, o
# deploy-failed.json e o failed_tag chegam na E7 de 09.
set -euo pipefail

# shellcheck source=/dev/null
source "${TNF_NODE_ENV:-/etc/tnf-node.env}"
S3="s3://$TNF_ARTIFACTS_BUCKET"
WORK="${TNF_WORK:-/var/lib/tnf}"
DB_INIT="${TNF_DB_INIT:-/usr/local/sbin/tnf-db-init}"
EXPECTED_WAIT_MAX=1200 # 20 min para os nós esperados ficarem Ready (04, seção 7, passo 1)
LOG="${TNF_CONVERGE_LOG:-/var/log/tnf-converge.log}"
mkdir -p "$WORK"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG"; }

is_leader() {
  [[ "$(docker node inspect self --format '{{.ManagerStatus.Leader}}' 2>/dev/null)" == true ]]
}

envval() { sed -n "s/^$1=//p" "$2" | tail -n 1; }

# write_status <state> <mensagem> <faltando> <sem_rotulo> <removidos>
# SERVICES_JSON traz a situação por serviço (passo 9).
write_status() {
  local services="${SERVICES_JSON:-}"
  [[ -n "$services" ]] || services='{}'
  jq -n --arg state "$1" --arg message "$2" --arg time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg manifest "${MANIFEST_HASH:-}" --arg leader "$(hostname)" \
    --arg missing "$3" --arg unlabeled "$4" --arg removed "$5" \
    --argjson services "$services" \
    '{state: $state, message: $message, time: $time, manifest_hash: $manifest, leader: $leader,
      missing_nodes: ($missing | split(" ") | map(select(. != ""))),
      unlabeled_nodes: ($unlabeled | split(" ") | map(select(. != ""))),
      removed_nodes: ($removed | split(" ") | map(select(. != ""))),
      services: $services}' |
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
  rm -rf "$WORK/stacks"
  aws s3 cp "$S3/stacks/" "$WORK/stacks/" --recursive --region "$TNF_REGION" --only-show-errors
  MANIFEST_HASH="$(jq -r .hash "$WORK/manifest.json")"
  EXPECTED_NODES="$(envval EXPECTED_NODES "$WORK/stack.env" | tr ',' ' ')"
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

# --- passo 4: rede overlay -------------------------------------------------------------

# Sem criptografia (06, seção 3). Attachable para as conferências manuais com
# um container avulso na rede (R3).
ensure_network() {
  if ! docker network inspect tnf-net >/dev/null 2>&1; then
    docker network create --driver overlay --attachable tnf-net >/dev/null
    log "rede tnf-net criada"
  fi
}

# --- passo 5: segredos Docker ------------------------------------------------------------

# Cada parâmetro /tnf/<env>/secrets/<nome> vira o segredo tnf_<nome> (06,
# seção 5), menos o db_admin_password, que só o db-init e o tnf-db-shell leem
# direto do SSM. O valor vai ao Docker pela entrada padrão, nunca como
# argumento. Segredo existente não é alterado (o Docker não permite).
ensure_secrets() {
  local params existing name value
  params="$(aws ssm get-parameters-by-path --path "/tnf/$TNF_ENV/secrets/" --with-decryption \
    --region "$TNF_REGION" --query 'Parameters[].[Name,Value]' --output json)" || return 1
  existing=" $(docker secret ls --format '{{.Name}}' | tr '\n' ' ') "
  while IFS=$'\t' read -r name value; do
    name="${name##*/}"
    [[ -n "$name" && "$name" != db_admin_password ]] || continue
    [[ "$existing" == *" tnf_$name "* ]] && continue
    printf '%s' "$value" | docker secret create "tnf_$name" - >/dev/null
    log "segredo tnf_$name criado"
  done < <(jq -r '.[] | @tsv' <<<"$params")
}

# --- passo 7: imagens resolvidas por digest (07, seção 5.2) ---------------------------------

# resolve_digest <namespace/repositório:etiqueta>: digest atual da etiqueta no
# Docker Hub, por uma consulta HEAD ao manifesto (não conta na cota de baixadas).
resolve_digest() {
  local repo="${1%:*}" tag="${1##*:}" token digest
  token="$(curl -fsS --max-time 15 "https://auth.docker.io/token?service=registry.docker.io&scope=repository:$repo:pull" | jq -r .token)" || return 1
  digest="$(curl -fsSI --max-time 15 -H "Authorization: Bearer $token" \
    -H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json" \
    "https://registry-1.docker.io/v2/$repo/manifests/$tag" | tr -d '\r' |
    awk -F': ' 'tolower($1) == "docker-content-digest" {print $2}')" || return 1
  [[ "$digest" == sha256:* ]] || return 1
  printf '%s' "$digest"
}

# build_effective_env: copia o stack.env e fixa por digest a imagem de cada
# serviço ligado (06, seção 4). Serviço desligado é pulado: a imagem dele nem
# é consultada (03, seção 3.4). UNRESOLVED lista o que não deu para consultar.
build_effective_env() {
  local svc replicas ref digest
  UNRESOLVED=""
  cp "$WORK/stack.env" "$WORK/effective.env.new"
  for svc in FRONTEND BACKEND MESSAGING; do
    replicas="$(envval "REPLICAS_$svc" "$WORK/stack.env")"
    ((${replicas:-0} > 0)) || continue
    ref="$(envval "IMAGE_$svc" "$WORK/stack.env")"
    if ! digest="$(resolve_digest "$ref")"; then
      UNRESOLVED="$UNRESOLVED $ref"
      continue
    fi
    sed -i "s|^IMAGE_$svc=.*|IMAGE_$svc=$ref@$digest|" "$WORK/effective.env.new"
  done
  UNRESOLVED="${UNRESOLVED# }"
  [[ -z "$UNRESOLVED" ]] || return 1
  mv "$WORK/effective.env.new" "$WORK/effective.env"
}

# --- passo 8: deploy das stacks ------------------------------------------------------------

# Só refaz o deploy quando o conjunto mudou: o stack.env efetivo (imagens por
# digest, réplicas) ou os compose files. Ordem: rabbitmq, app e web; a
# mensageria só entra na tnf-app quando ligada, e o --prune a remove ao
# desligar (06, seção 2).
deploy_stacks() {
  local hash
  hash="$(cat "$WORK/effective.env" "$WORK"/stacks/*.yml | sha256sum | cut -d' ' -f1)"
  [[ "$(cat "$WORK/deployed.hash" 2>/dev/null)" == "$hash" ]] && return 0
  (
    set -a
    # shellcheck source=/dev/null
    source "$WORK/effective.env"
    set +a
    cd "$WORK/stacks"
    app=(-c app.yml)
    if ((${REPLICAS_MESSAGING:-0} > 0)); then
      app+=(-c app-messaging.yml)
    fi
    # Encadeado com &&: dentro de "( ) || return" o set -e não vale.
    docker stack deploy --detach=true -c rabbitmq.yml tnf-rabbitmq &&
      docker stack deploy --detach=true --prune "${app[@]}" tnf-app &&
      docker stack deploy --detach=true -c web.yml tnf-web
  ) >>"$LOG" 2>&1 || return 1
  printf '%s' "$hash" >"$WORK/deployed.hash"
  log "stacks implantadas (conjunto $hash)"
}

# --- passo 9: situação por serviço ---------------------------------------------------------

# service_status: SERVICES_JSON com réplicas e imagem de cada serviço, e
# PENDING_SERVICES com os ligados que ainda não têm todas as réplicas
# saudáveis. Desligado aparece como "off" e não conta (04, seção 7, passo 9).
service_status() {
  local entry svc name env_key desired running image state table
  SERVICES_JSON="{}" PENDING_SERVICES=""
  table="$(docker service ls --format '{{.Name}} {{.Replicas}}' 2>/dev/null || true)"
  for entry in rabbitmq:tnf-rabbitmq_rabbitmq:- backend:tnf-app_backend-som:BACKEND \
    messaging:tnf-app_messaging:MESSAGING frontend:tnf-web_frontend:FRONTEND; do
    IFS=: read -r svc name env_key <<<"$entry"
    if [[ "$env_key" == - ]]; then
      desired=1 image=""
    else
      desired="$(envval "REPLICAS_$env_key" "$WORK/stack.env")"
      image=""
      [[ -f "$WORK/effective.env" ]] && image="$(envval "IMAGE_$env_key" "$WORK/effective.env")"
    fi
    running="$(awk -v n="$name" '$1 == n {split($2, r, "/"); print r[1]}' <<<"$table")"
    running="${running:-0}"
    if ((${desired:-0} == 0)); then
      state=off image=""
    elif ((running >= desired)); then
      state=ok
    else
      state=starting
      PENDING_SERVICES="$PENDING_SERVICES $svc ($running/$desired)"
    fi
    SERVICES_JSON="$(jq -c --arg s "$svc" --arg st "$state" --arg img "$image" \
      --argjson d "${desired:-0}" --argjson r "$running" \
      '.[$s] = {state: $st, desired: $d, running: $r, image: $img}' <<<"$SERVICES_JSON")"
  done
  PENDING_SERVICES="${PENDING_SERVICES# }"
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
  ensure_network

  local secrets_ok=true
  ensure_secrets || secrets_ok=false

  # Passo 6: banco (04, seção 7; 05, B5). Saída: ok, waiting <msg> ou failed <msg>.
  local db
  db="$("$DB_INIT" "$WORK/stack.env" "$MANIFEST_HASH" 2>>"$LOG")" ||
    db="failed o db-init terminou com erro inesperado; veja /var/log/tnf-db-init.log no líder"
  DB_STATE="${db%% *}"
  DB_MSG="${db#* }"
  [[ "$DB_STATE" == ok ]] && DB_MSG=""

  # Passos 7 e 8: só com segredos e banco prontos (o backend precisa dos dois).
  local deploy_msg=""
  if [[ "$secrets_ok" == true && "$DB_STATE" == ok ]]; then
    if ! build_effective_env; then
      deploy_msg="não foi possível consultar o Docker Hub para: $UNRESOLVED. Confira se a imagem e a etiqueta existem (a etiqueta vem de image_tags e do workflow de deploy, 07); nova tentativa em 60 s."
    elif ! deploy_stacks; then
      deploy_msg="o docker stack deploy falhou; veja $LOG no líder. Nova tentativa em 60 s."
    fi
  fi
  service_status

  local state=ready msg="todos os nós esperados estão Ready e rotulados, o banco está inicializado e os serviços ligados estão com todas as réplicas"
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
  elif [[ "$secrets_ok" != true ]]; then
    state=waiting
    msg="não foi possível ler os segredos em /tnf/$TNF_ENV/secrets/ no SSM; nova tentativa em 60 s."
  elif [[ "$DB_STATE" == waiting ]]; then
    state=waiting
    msg="banco: $DB_MSG"
  elif [[ -n "$deploy_msg" ]]; then
    state=waiting
    msg="$deploy_msg"
  elif [[ -n "$PENDING_SERVICES" ]]; then
    state=waiting
    msg="aguardando as réplicas saudáveis de: $PENDING_SERVICES"
  fi
  write_status "$state" "$msg" "$MISSING" "${UNLABELED# }" "${REMOVED# }"
  log "converge: $state ($msg)"
}

main "$@"
