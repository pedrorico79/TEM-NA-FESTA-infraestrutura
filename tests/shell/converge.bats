#!/usr/bin/env bats
# Testes do node/converge.sh (04, seção 7, passos 4, 5, 7, 8 e 9) com docker,
# aws, curl e db-init simulados: rede, segredos, imagens fixadas por digest,
# deploy das stacks na ordem e situação por serviço no converge.json.

bats_require_minimum_version 1.5.0

CONVERGE="$BATS_TEST_DIRNAME/../../node/converge.sh"
STACKS="$BATS_TEST_DIRNAME/../../stacks"

setup() {
  W="$BATS_TEST_TMPDIR"
  BIN="$W/bin"
  mkdir -p "$BIN" "$W/s3/stacks" "$W/secret-values"
  export W CALLS="$W/calls"
  : >"$CALLS"
  : >"$W/secrets"
  : >"$W/services"
  export TNF_NODE_ENV="$W/node.env" TNF_WORK="$W/work" TNF_DB_INIT="$BIN/db-init" TNF_CONVERGE_LOG="$W/converge.log"
  cat >"$TNF_NODE_ENV" <<'EOF'
TNF_ENV=dev
TNF_REGION=us-east-1
TNF_ARTIFACTS_BUCKET=artefatos
EOF
  cat >"$W/s3/stack.env" <<'EOF'
DB_ENDPOINT=banco.exemplo.invalid
DB_NAME=tem_na_festa
DB_USER=tnf_app
EXPECTED_NODES=tem-na-festa-dev-web-1,tem-na-festa-dev-app-1
IMAGE_BACKEND=ns/tnf-backend:dev
IMAGE_FRONTEND=ns/tnf-frontend:dev
IMAGE_MESSAGING=ns/tnf-messaging:dev
MANAGER_COUNT=1
MESSAGING_PORT=
REPLICAS_BACKEND=1
REPLICAS_FRONTEND=1
REPLICAS_MESSAGING=0
EOF
  echo '{"hash":"h1"}' >"$W/s3/manifest.json"
  cp "$STACKS"/*.yml "$W/s3/stacks/"
  printf 'tem-na-festa-dev-web-1 Ready worker\ntem-na-festa-dev-app-1 Ready manager\n' >"$W/nodes"

  stub docker <<'EOF'
echo "docker $*" >>"$CALLS"
case "$1 $2" in
  "node inspect") echo true ;;
  "node ls")
    if [[ "$*" == *Status* ]]; then cat "$W/nodes"; else awk '{print $1}' "$W/nodes"; fi ;;
  "network inspect") [[ -f "$W/net" ]]; exit $? ;;
  "network create") touch "$W/net" ;;
  "secret ls") cat "$W/secrets" ;;
  "secret create") cat >"$W/secret-values/$3"; echo "$3" >>"$W/secrets" ;;
  "stack deploy")
    stack="${*: -1}"
    echo "deploy $stack IMAGE_BACKEND=${IMAGE_BACKEND:-} IMAGE_FRONTEND=${IMAGE_FRONTEND:-} IMAGE_MESSAGING=${IMAGE_MESSAGING:-}" >>"$W/deploys"
    [[ "${DEPLOY_FAIL:-}" == "$stack" ]] && exit 1
    # Serviços simulados em $W/svc/<nome>.image (e .previous quando a imagem muda).
    set_img() {
      mkdir -p "$W/svc"
      local f="$W/svc/$1"
      if [[ -f "$f.image" && "$(cat "$f.image")" != "$2" ]]; then cp "$f.image" "$f.previous"; echo completed >"$f.update"; fi
      printf '%s' "$2" >"$f.image"
    }
    case "$stack" in
      tnf-rabbitmq) set_img tnf-rabbitmq_rabbitmq rabbitmq:4.1.4 ;;
      tnf-app)
        set_img tnf-app_backend-som "$IMAGE_BACKEND"
        [[ "$*" == *app-messaging.yml* ]] && set_img tnf-app_messaging "$IMAGE_MESSAGING" ;;
      tnf-web) set_img tnf-web_frontend "$IMAGE_FRONTEND" ;;
    esac ;;
  "service inspect")
    f="$W/svc/$3"
    [[ -f "$f.image" ]] || exit 1
    case "$*" in
      *UpdateStatus*) cat "$f.update" 2>/dev/null ;;
      *PreviousSpec*) cat "$f.previous" 2>/dev/null ;;
      *ContainerSpec.Image*) cat "$f.image" ;;
    esac ;;
  "service ls") cat "$W/services" ;;
esac
exit 0
EOF

  stub aws <<'EOF'
echo "aws $*" >>"$CALLS"
case "$1 $2" in
  "s3api head-object") exit "${READY_RC:-0}" ;;
  "s3 cp")
    if [[ "$3" == - ]]; then cat >"$W/converge.json"
    elif [[ "$3" == */stacks/ ]]; then mkdir -p "$4"; cp "$W/s3/stacks/"* "$4"
    elif [[ "$4" == s3://* ]]; then cp "$3" "$W/s3/${4##*/}"
    else cp "$W/s3/${3##*/}" "$4"; fi ;;
  "ssm get-parameters-by-path")
    [[ "${SSM_FAIL:-0}" == 1 ]] && exit 1
    echo '[["/tnf/dev/secrets/db_admin_password","admin123"],["/tnf/dev/secrets/db_password","senhaApp1"],["/tnf/dev/secrets/jwt_secret","jwt456"],["/tnf/dev/secrets/rabbitmq_user","tnf_rabbit"]]' ;;
esac
exit 0
EOF

  # Docker Hub: token; HEAD do manifesto com o digest da etiqueta (derivado do
  # nome, ou o de $W/digest.<repositório>); GET do manifesto e da configuração
  # com a label do commit.
  stub curl <<'EOF'
echo "curl $*" >>"$CALLS"
url="${*: -1}"
if [[ "$url" == *auth.docker.io* ]]; then echo '{"token":"t"}'; exit 0; fi
repo="${url#https://registry-1.docker.io/v2/}"; repo="${repo%%/manifests/*}"; repo="${repo%%/blobs/*}"
[[ " ${UNRESOLVED_REPOS:-} " == *" $repo "* ]] && exit 22
if [[ "$url" == */blobs/* ]]; then
  echo '{"config":{"Labels":{"org.opencontainers.image.revision":"abc1234def5678"}}}'
elif [[ " $* " == *" -fsSI "* ]]; then
  digest="$(cat "$W/digest.${repo##*/}" 2>/dev/null || echo "sha256:${repo##*/}")"
  printf 'HTTP/2 200\r\ndocker-content-digest: %s\r\n\r\n' "$digest"
else
  echo '{"config":{"digest":"sha256:cfg"}}'
fi
EOF

  stub db-init <<'EOF'
echo "${DB_RESULT:-ok}"
EOF
}

stub() {
  cat >"$BIN/$1" <<<"#!/usr/bin/env bash
$(cat)"
  chmod +x "$BIN/$1"
}

converge() { PATH="$BIN:$PATH" run bash "$CONVERGE"; }
state() { jq -r .state "$W/converge.json"; }

@test "cria a rede tnf-net e os segredos tnf_<nome>, menos o db_admin_password, com o valor pela entrada padrão" {
  converge
  [ "$status" -eq 0 ]
  grep -q "docker network create --driver overlay --attachable tnf-net" "$CALLS"
  [ "$(sort "$W/secrets" | tr '\n' ' ')" = "tnf_db_password tnf_jwt_secret tnf_rabbitmq_user " ]
  [ "$(cat "$W/secret-values/tnf_db_password")" = "senhaApp1" ]
  run ! grep -q "admin123\|senhaApp1\|jwt456" "$CALLS"
}

@test "segredo que já existe não é recriado" {
  echo tnf_jwt_secret >"$W/secrets"
  converge
  [ "$status" -eq 0 ]
  run ! grep -q "secret create tnf_jwt_secret" "$CALLS"
  grep -q "secret create tnf_db_password" "$CALLS"
}

@test "implanta rabbitmq, app e web nessa ordem, com as imagens fixadas por digest e a mensageria fora" {
  converge
  [ "$status" -eq 0 ]
  [ "$(awk '{print $2}' "$W/deploys" | tr '\n' ' ')" = "tnf-rabbitmq tnf-app tnf-web " ]
  grep -q "IMAGE_BACKEND=ns/tnf-backend:dev@sha256:tnf-backend IMAGE_FRONTEND=ns/tnf-frontend:dev@sha256:tnf-frontend" "$W/deploys"
  grep -q "stack deploy --detach=true --prune -c app.yml tnf-app" "$CALLS"
  run ! grep -q "app-messaging.yml" "$CALLS"
  run ! grep -q "tnf-messaging" "$CALLS"
}

@test "com a mensageria ligada, a tnf-app recebe também o app-messaging.yml e a imagem dela é resolvida" {
  sed -i 's/^REPLICAS_MESSAGING=0/REPLICAS_MESSAGING=1/' "$W/s3/stack.env"
  converge
  [ "$status" -eq 0 ]
  grep -q "stack deploy --detach=true --prune -c app.yml -c app-messaging.yml tnf-app" "$CALLS"
  grep -q "IMAGE_MESSAGING=ns/tnf-messaging:dev@sha256:tnf-messaging" "$W/deploys"
}

@test "sem mudança no conjunto, a convergência seguinte não refaz o deploy" {
  converge
  converge
  [ "$(wc -l <"$W/deploys")" -eq 3 ]
}

@test "mudança de réplicas no stack.env refaz o deploy" {
  converge
  sed -i 's/^REPLICAS_FRONTEND=1/REPLICAS_FRONTEND=2/' "$W/s3/stack.env"
  converge
  [ "$(wc -l <"$W/deploys")" -eq 6 ]
}

@test "com réplicas subindo, o estado é waiting nomeando os serviços; a mensageria aparece como off" {
  printf 'tnf-rabbitmq_rabbitmq 1/1\ntnf-app_backend-som 0/1\ntnf-web_frontend 1/1\n' >"$W/services"
  converge
  [ "$(state)" = waiting ]
  [[ "$(jq -r .message "$W/converge.json")" == *"backend (0/1)"* ]]
  [ "$(jq -r .services.messaging.state "$W/converge.json")" = off ]
  [ "$(jq -r .services.backend.image "$W/converge.json")" = "ns/tnf-backend:dev@sha256:tnf-backend" ]
}

@test "com todas as réplicas, o estado é ready e cada serviço ligado está ok" {
  printf 'tnf-rabbitmq_rabbitmq 1/1\ntnf-app_backend-som 1/1\ntnf-web_frontend 1/1\n' >"$W/services"
  converge
  [ "$(state)" = ready ]
  [ "$(jq -r '[.services[] | .state] | join(" ")' "$W/converge.json")" = "ok ok ok off" ]
}

@test "banco ainda não pronto: nada é implantado e o estado diz o motivo" {
  export DB_RESULT="waiting aguardando o RDS aceitar conexão"
  converge
  [ ! -f "$W/deploys" ]
  [ "$(state)" = waiting ]
  [[ "$(jq -r .message "$W/converge.json")" == "banco: aguardando o RDS"* ]]
}

@test "imagem que não se resolve no Docker Hub: nada é implantado e a mensagem nomeia a imagem" {
  export UNRESOLVED_REPOS="ns/tnf-frontend"
  converge
  [ ! -f "$W/deploys" ]
  [ "$(state)" = waiting ]
  [[ "$(jq -r .message "$W/converge.json")" == *"Docker Hub para: ns/tnf-frontend:dev"* ]]
}

@test "falha do deploy da tnf-app interrompe a ordem e tenta de novo no ciclo seguinte" {
  export DEPLOY_FAIL=tnf-app
  converge
  [ "$(awk '{print $2}' "$W/deploys" | tr '\n' ' ')" = "tnf-rabbitmq tnf-app " ]
  [[ "$(jq -r .message "$W/converge.json")" == *"o docker stack deploy falhou"* ]]
  unset DEPLOY_FAIL
  converge
  [ "$(wc -l <"$W/deploys")" -eq 5 ]
}

@test "SSM inacessível: nada é implantado e o estado é waiting" {
  export SSM_FAIL=1
  converge
  [ ! -f "$W/deploys" ]
  [[ "$(jq -r .message "$W/converge.json")" == *"segredos em /tnf/dev/secrets/"* ]]
}

# --- E7: deploy contínuo (07, seção 5.2) -------------------------------------------

all_running() { printf 'tnf-rabbitmq_rabbitmq 1/1\ntnf-app_backend-som 1/1\ntnf-web_frontend 1/1\n' >"$W/services"; }

@test "S8: a etiqueta do backend passa a outro digest e só o backend muda de imagem" {
  all_running
  converge
  echo sha256:backend-v2 >"$W/digest.tnf-backend"
  converge
  [ "$(cat "$W/svc/tnf-app_backend-som.image")" = "ns/tnf-backend:dev@sha256:backend-v2" ]
  [ "$(cat "$W/svc/tnf-web_frontend.image")" = "ns/tnf-frontend:dev@sha256:tnf-frontend" ]
  [ ! -f "$W/svc/tnf-web_frontend.previous" ]
  [ "$(state)" = ready ]
  [ "$(jq -r .services.backend.running_digest "$W/converge.json")" = "sha256:backend-v2" ]
  [ "$(jq -r .services.backend.tag_digest "$W/converge.json")" = "sha256:backend-v2" ]
}

# Simula o rollback do Swarm: a imagem nova volta para a anterior.
swarm_rollback() {
  local f="$W/svc/$1"
  cp "$f.image" "$f.bad"
  cp "$f.previous" "$f.image"
  cp "$f.bad" "$f.previous"
  echo rollback_completed >"$f.update"
}

# Leva o backend a um digest ruim que o Swarm reverte.
bad_backend_rolled_back() {
  all_running
  converge
  echo sha256:backend-ruim >"$W/digest.tnf-backend"
  converge
  swarm_rollback tnf-app_backend-som
  converge
}

@test "C5: digest revertido pelo Swarm vai para o deploy-failed.json, com o commit, e não é tentado de novo" {
  bad_backend_rolled_back
  [ "$(jq -r '.backend[0].digest' "$W/s3/deploy-failed.json")" = "sha256:backend-ruim" ]
  [ "$(jq -r '.backend[0].commit' "$W/s3/deploy-failed.json")" = "abc1234" ]
  [ "$(cat "$W/svc/tnf-app_backend-som.image")" = "ns/tnf-backend:dev@sha256:tnf-backend" ]
  [ "$(state)" = degraded ]
  [ "$(jq -r .services.backend.state "$W/converge.json")" = failed_tag ]
  [[ "$(jq -r .message "$W/converge.json")" == *"a etiqueta dev aponta para uma imagem que falhou (commit abc1234). Rodando: versão anterior."*"reuse_tag=sha-<anterior>"* ]]
  [ "$(jq -r .services.frontend.state "$W/converge.json")" = ok ]
  local before
  before="$(wc -l <"$W/deploys")"
  converge
  run grep -c "backend-ruim" <(tail -n +"$((before + 1))" "$W/deploys")
  [ "$output" = 0 ]
}

@test "C14: depois do C5, a etiqueta corrigida atualiza o serviço e o ambiente volta a ready" {
  bad_backend_rolled_back
  echo sha256:backend-bom >"$W/digest.tnf-backend"
  converge
  [ "$(cat "$W/svc/tnf-app_backend-som.image")" = "ns/tnf-backend:dev@sha256:backend-bom" ]
  [ "$(state)" = ready ]
  [ "$(jq -r .services.backend.state "$W/converge.json")" = ok ]
}

@test "C13, S11: ambiente novo com imagem ruim: passados 10 min sem réplicas, failed_tag e degraded, sem mexer no frontend" {
  printf 'tnf-rabbitmq_rabbitmq 1/1\ntnf-app_backend-som 0/1\ntnf-web_frontend 1/1\n' >"$W/services"
  converge
  [ "$(state)" = waiting ]
  echo $(($(date +%s) - 700)) >"$W/work/since.backend"
  converge
  [ "$(state)" = degraded ]
  [ "$(jq -r .services.backend.state "$W/converge.json")" = failed_tag ]
  [[ "$(jq -r .services.backend.message "$W/converge.json")" == *"Rodando: nenhuma réplica saudável."* ]]
  [ "$(jq -r '.backend[0].reason' "$W/s3/deploy-failed.json")" = "sem as réplicas desejadas em 10 minutos" ]
  [ "$(jq -r .services.frontend.state "$W/converge.json")" = ok ]
}

@test "o prazo de 10 min recomeça quando a imagem do serviço muda" {
  printf 'tnf-rabbitmq_rabbitmq 1/1\ntnf-app_backend-som 0/1\ntnf-web_frontend 1/1\n' >"$W/services"
  converge
  echo $(($(date +%s) - 700)) >"$W/work/since.backend"
  echo sha256:backend-v2 >"$W/digest.tnf-backend"
  converge
  [ "$(state)" = waiting ]
  [ ! -f "$W/s3/deploy-failed.json" ]
}
