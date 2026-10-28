#!/usr/bin/env bash
# Convergência do ambiente (04, seção 7), executada a cada 60 s pelo
# tnf-converge.timer em todos os managers; só age no líder atual do Swarm.
# Passos: READY e download dos arquivos (3), nós esperados e limpeza (1),
# rótulos (2), rede tnf-net (4), segredos Docker (5), banco (6, tnf-db-init),
# imagens resolvidas por digest (7), deploy das stacks na ordem rabbitmq, app
# e web (8) e status por serviço (9). O passo 7 também é o deploy contínuo
# (07, seção 5.2): quando a etiqueta do ambiente aponta para outro digest, o
# serviço é atualizado; um digest que o Swarm reverteu, ou que não chegou às
# réplicas em 10 min, vai para status/deploy-failed.json e o serviço fica
# failed_tag até a etiqueta apontar para outro.
set -euo pipefail

# shellcheck source=/dev/null
source "${TNF_NODE_ENV:-/etc/tnf-node.env}"
S3="s3://$TNF_ARTIFACTS_BUCKET"
WORK="${TNF_WORK:-/var/lib/tnf}"
DB_INIT="${TNF_DB_INIT:-/usr/local/sbin/tnf-db-init}"
EXPECTED_WAIT_MAX=1200 # 20 min para os nós esperados ficarem Ready (04, seção 7, passo 1)
HEALTH_DEADLINE=600    # 10 min para um serviço chegar às réplicas depois de mudar de imagem (04, passo 9)
FAILED_KEY=status/deploy-failed.json
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

MANIFEST_ACCEPT="application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json"

# Serviço do converge.json => nome no Swarm e chave do stack.env.
declare -A SWARM_NAME=([frontend]=tnf-web_frontend [backend]=tnf-app_backend-som [messaging]=tnf-app_messaging)
declare -A ENV_KEY=([frontend]=FRONTEND [backend]=BACKEND [messaging]=MESSAGING)
APP_SERVICES="frontend backend messaging"

registry_token() {
  curl -fsS --max-time 15 "https://auth.docker.io/token?service=registry.docker.io&scope=repository:$1:pull" | jq -r .token
}

# resolve_digest <namespace/repositório:etiqueta>: digest atual da etiqueta no
# Docker Hub, por uma consulta HEAD ao manifesto (não conta na cota de baixadas).
resolve_digest() {
  local repo="${1%:*}" tag="${1##*:}" token digest
  token="$(registry_token "$repo")" || return 1
  digest="$(curl -fsSI --max-time 15 -H "Authorization: Bearer $token" -H "Accept: $MANIFEST_ACCEPT" \
    "https://registry-1.docker.io/v2/$repo/manifests/$tag" | tr -d '\r' |
    awk -F': ' 'tolower($1) == "docker-content-digest" {print $2}')" || return 1
  [[ "$digest" == sha256:* ]] || return 1
  printf '%s' "$digest"
}

# image_commit <namespace/repositório> <digest>: os 7 primeiros caracteres do
# commit da label org.opencontainers.image.revision (07, seção 3), lida da
# configuração da imagem no registro; vazio se não houver.
image_commit() {
  local repo="$1" digest="$2" token manifest cfg
  token="$(registry_token "$repo")" || return 0
  manifest="$(curl -fsS --max-time 15 -H "Authorization: Bearer $token" -H "Accept: $MANIFEST_ACCEPT" \
    "https://registry-1.docker.io/v2/$repo/manifests/$digest")" || return 0
  if jq -e .manifests >/dev/null 2>&1 <<<"$manifest"; then
    digest="$(jq -r '[.manifests[] | select(.platform.os == "linux" and .platform.architecture == "amd64")][0].digest // empty' <<<"$manifest")"
    [[ -n "$digest" ]] || return 0
    manifest="$(curl -fsS --max-time 15 -H "Authorization: Bearer $token" -H "Accept: $MANIFEST_ACCEPT" \
      "https://registry-1.docker.io/v2/$repo/manifests/$digest")" || return 0
  fi
  cfg="$(jq -r '.config.digest // empty' <<<"$manifest")"
  [[ -n "$cfg" ]] || return 0
  curl -fsSL --max-time 15 -H "Authorization: Bearer $token" "https://registry-1.docker.io/v2/$repo/blobs/$cfg" |
    jq -r '.config.Labels["org.opencontainers.image.revision"] // empty' | cut -c1-7 || true
}

digest_of() { if [[ "$1" == *@sha256:* ]]; then printf "%s" "${1##*@}"; fi; }

# --- deploy-failed.json ------------------------------------------------------------------

# {"backend": [{"digest", "tag", "commit", "time"}], ...}: digests que não ficaram
# saudáveis, por serviço. Some com o bucket de artefatos no infra down (07, F9).
load_failed() {
  aws s3 cp "$S3/$FAILED_KEY" "$WORK/deploy-failed.json" --region "$TNF_REGION" --only-show-errors 2>/dev/null ||
    echo '{}' >"$WORK/deploy-failed.json"
}

is_failed() {
  jq -e --arg s "$1" --arg d "$2" '(.[$s] // []) | any(.digest == $d)' "$WORK/deploy-failed.json" >/dev/null
}

# record_failed <serviço> <digest> <motivo>
record_failed() {
  local svc="$1" digest="$2" reason="$3" ref commit
  is_failed "$svc" "$digest" && return 0
  ref="$(envval "IMAGE_${ENV_KEY[$svc]}" "$WORK/stack.env")"
  commit="$(image_commit "${ref%:*}" "$digest")"
  jq --arg s "$svc" --arg d "$digest" --arg t "${ref##*:}" --arg c "$commit" --arg r "$reason" \
    --arg time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '.[$s] = ((.[$s] // []) + [{digest: $d, tag: $t, commit: $c, reason: $r, time: $time}])' \
    "$WORK/deploy-failed.json" >"$WORK/deploy-failed.json.new"
  mv "$WORK/deploy-failed.json.new" "$WORK/deploy-failed.json"
  aws s3 cp "$WORK/deploy-failed.json" "$S3/$FAILED_KEY" --region "$TNF_REGION" --only-show-errors
  log "digest $digest do $svc anotado como falho ($reason${commit:+, commit $commit})"
}

# --- passo 7: etiquetas, falhas e imagens efetivas -----------------------------------------

# resolve_tags: TAG_DIGEST[serviço] de cada serviço ligado. Desligado é pulado:
# a imagem dele nem é consultada (03, seção 3.4). UNRESOLVED lista o que falhou.
declare -A TAG_DIGEST=()
resolve_tags() {
  local svc replicas ref digest
  UNRESOLVED=""
  for svc in $APP_SERVICES; do
    replicas="$(envval "REPLICAS_${ENV_KEY[$svc]}" "$WORK/stack.env")"
    ((${replicas:-0} > 0)) || continue
    ref="$(envval "IMAGE_${ENV_KEY[$svc]}" "$WORK/stack.env")"
    if digest="$(resolve_digest "$ref")"; then
      TAG_DIGEST[$svc]="$digest"
    else
      UNRESOLVED="$UNRESOLVED $ref"
    fi
  done
  UNRESOLVED="${UNRESOLVED# }"
  [[ -z "$UNRESOLVED" ]]
}

# detect_failures: anota o digest da etiqueta como falho quando (a) o Swarm
# reverteu a atualização para ele (ambiente no ar) ou (b) o serviço está com
# ele há mais de 10 min sem as réplicas desejadas (ambiente novo, sem versão
# anterior para reverter).
detect_failures() {
  local svc name tag update previous image since desired running
  for svc in "${!TAG_DIGEST[@]}"; do
    name="${SWARM_NAME[$svc]}" tag="${TAG_DIGEST[$svc]}"
    docker service inspect "$name" >/dev/null 2>&1 || continue
    update="$(docker service inspect "$name" --format '{{if .UpdateStatus}}{{.UpdateStatus.State}}{{end}}')"
    previous="$(docker service inspect "$name" --format '{{if .PreviousSpec}}{{.PreviousSpec.TaskTemplate.ContainerSpec.Image}}{{end}}')"
    if [[ "$update" == rollback_* && "$(digest_of "$previous")" == "$tag" ]]; then
      record_failed "$svc" "$tag" "o Swarm reverteu a atualização"
      continue
    fi
    image="$(docker service inspect "$name" --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}')"
    [[ "$(digest_of "$image")" == "$tag" ]] || continue
    since="$(cat "$WORK/since.$svc" 2>/dev/null || date +%s)"
    desired="$(envval "REPLICAS_${ENV_KEY[$svc]}" "$WORK/stack.env")"
    running="$(docker service ls --filter "name=$name" --format '{{.Name}} {{.Replicas}}' |
      awk -v n="$name" '$1 == n {split($2, r, "/"); print r[1]}')"
    if ((${running:-0} < desired && $(date +%s) - since > HEALTH_DEADLINE)); then
      record_failed "$svc" "$tag" "sem as réplicas desejadas em $((HEALTH_DEADLINE / 60)) minutos"
    fi
  done
}

# build_effective_env: copia o stack.env e fixa por digest a imagem de cada
# serviço ligado (06, seção 4). Com o digest da etiqueta anotado como falho, o
# serviço fica na imagem que roda (FAILED_TAG). A hora em que a imagem de um
# serviço muda fica em since.<serviço>, para o prazo de 10 min.
declare -A FAILED_TAG=()
build_effective_env() {
  local svc ref tag image current old
  cp "$WORK/stack.env" "$WORK/effective.env.new"
  for svc in "${!TAG_DIGEST[@]}"; do
    ref="$(envval "IMAGE_${ENV_KEY[$svc]}" "$WORK/stack.env")"
    tag="${TAG_DIGEST[$svc]}"
    image="$ref@$tag"
    if is_failed "$svc" "$tag"; then
      FAILED_TAG[$svc]=1
      current="$(docker service inspect "${SWARM_NAME[$svc]}" --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}' 2>/dev/null || true)"
      [[ -n "$current" ]] && image="$current"
    fi
    sed -i "s|^IMAGE_${ENV_KEY[$svc]}=.*|IMAGE_${ENV_KEY[$svc]}=$image|" "$WORK/effective.env.new"
    old="$(envval "IMAGE_${ENV_KEY[$svc]}" "$WORK/effective.env" 2>/dev/null || true)"
    [[ "$old" == "$image" && -f "$WORK/since.$svc" ]] || date +%s >"$WORK/since.$svc"
  done
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

# service_status: SERVICES_JSON com, por serviço, a situação (ok, starting,
# failed_tag ou off), as réplicas, a imagem em execução, o digest dela e o da
# etiqueta (04, seção 7, passo 9); PENDING_SERVICES com os ligados ainda sem
# todas as réplicas e FAILED_MSGS com a mensagem acionável de 07, seção 5.2.
service_status() {
  local svc name desired running image tag state table commit etiqueta now_running msg
  SERVICES_JSON="{}" PENDING_SERVICES="" FAILED_MSGS=""
  table="$(docker service ls --format '{{.Name}} {{.Replicas}}' 2>/dev/null || true)"
  for svc in rabbitmq $APP_SERVICES; do
    if [[ "$svc" == rabbitmq ]]; then
      name=tnf-rabbitmq_rabbitmq desired=1
    else
      name="${SWARM_NAME[$svc]}"
      desired="$(envval "REPLICAS_${ENV_KEY[$svc]}" "$WORK/stack.env")"
    fi
    image="$(docker service inspect "$name" --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}' 2>/dev/null || true)"
    tag="${TAG_DIGEST[$svc]:-}"
    running="$(awk -v n="$name" '$1 == n {split($2, r, "/"); print r[1]}' <<<"$table")"
    running="${running:-0}"
    msg=""
    if ((${desired:-0} == 0)); then
      state=off image="" tag=""
    elif [[ -n "${FAILED_TAG[$svc]:-}" ]]; then
      state=failed_tag
      commit="$(jq -r --arg s "$svc" --arg d "$tag" '[(.[$s] // [])[] | select(.digest == $d)][0].commit // empty' "$WORK/deploy-failed.json")"
      etiqueta="$(envval "IMAGE_${ENV_KEY[$svc]}" "$WORK/stack.env")"
      etiqueta="${etiqueta##*:}"
      now_running="versão anterior"
      if [[ "$(digest_of "$image")" == "$tag" ]] || ((running == 0)); then
        now_running="nenhuma réplica saudável"
      fi
      msg="$svc: a etiqueta $etiqueta aponta para uma imagem que falhou${commit:+ (commit $commit)}. Rodando: $now_running. Ação: rode o deploy do $svc com a branch corrigida ou com reuse_tag=sha-<anterior>."
      FAILED_MSGS="$FAILED_MSGS $msg"
    elif ((running >= desired)); then
      state=ok
    else
      state=starting
      PENDING_SERVICES="$PENDING_SERVICES $svc ($running/$desired)"
    fi
    SERVICES_JSON="$(jq -c --arg s "$svc" --arg st "$state" --arg img "$image" \
      --arg run "$(digest_of "$image")" --arg tag "$tag" --arg msg "$msg" \
      --argjson d "${desired:-0}" --argjson r "$running" \
      '.[$s] = {state: $st, desired: $d, running: $r, image: $img, running_digest: $run, tag_digest: $tag}
        + (if $msg == "" then {} else {message: $msg} end)' <<<"$SERVICES_JSON")"
  done
  PENDING_SERVICES="${PENDING_SERVICES# }"
  FAILED_MSGS="${FAILED_MSGS# }"
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
  # Com a mensageria ligada, o schema do microsserviço também (E8), depois do
  # do backend; o pior dos dois resultados vale.
  if [[ "${db%% *}" == ok ]] && (($(envval REPLICAS_MESSAGING "$WORK/stack.env") > 0)); then
    db="$("$DB_INIT" "$WORK/stack.env" "$MANIFEST_HASH" messaging 2>>"$LOG")" ||
      db="failed o db-init do microsserviço terminou com erro inesperado; veja /var/log/tnf-db-init.log no líder"
    [[ "${db%% *}" == ok ]] || db="${db%% *} microsserviço: ${db#* }"
  fi
  DB_STATE="${db%% *}"
  DB_MSG="${db#* }"
  [[ "$DB_STATE" == ok ]] && DB_MSG=""

  # Passos 7 e 8: só com segredos e banco prontos (o backend precisa dos dois).
  local deploy_msg=""
  echo '{}' >"$WORK/deploy-failed.json"
  if [[ "$secrets_ok" == true && "$DB_STATE" == ok ]]; then
    load_failed
    if ! resolve_tags; then
      deploy_msg="não foi possível consultar o Docker Hub para: $UNRESOLVED. Confira se a imagem e a etiqueta existem (a etiqueta vem de image_tags e do workflow de deploy, 07); nova tentativa em 60 s."
    else
      detect_failures
      build_effective_env
      deploy_stacks || deploy_msg="o docker stack deploy falhou; veja $LOG no líder. Nova tentativa em 60 s."
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
  elif [[ -n "$FAILED_MSGS" ]]; then
    state=degraded
    msg="$FAILED_MSGS"
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
