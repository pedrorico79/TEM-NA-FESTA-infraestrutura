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
    echo "deploy ${*: -1} IMAGE_BACKEND=${IMAGE_BACKEND:-} IMAGE_FRONTEND=${IMAGE_FRONTEND:-} IMAGE_MESSAGING=${IMAGE_MESSAGING:-}" >>"$W/deploys"
    [[ "${DEPLOY_FAIL:-}" == "${*: -1}" ]] && exit 1 ;;
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
    else cp "$W/s3/${3##*/}" "$4"; fi ;;
  "ssm get-parameters-by-path")
    [[ "${SSM_FAIL:-0}" == 1 ]] && exit 1
    echo '[["/tnf/dev/secrets/db_admin_password","admin123"],["/tnf/dev/secrets/db_password","senhaApp1"],["/tnf/dev/secrets/jwt_secret","jwt456"],["/tnf/dev/secrets/rabbitmq_user","tnf_rabbit"]]' ;;
esac
exit 0
EOF

  # Token e HEAD do manifesto no Docker Hub; o digest é derivado do nome.
  stub curl <<'EOF'
echo "curl $*" >>"$CALLS"
url="${*: -1}"
if [[ "$url" == *auth.docker.io* ]]; then echo '{"token":"t"}'; exit 0; fi
repo="${url#https://registry-1.docker.io/v2/}"; repo="${repo%/manifests/*}"
[[ " ${UNRESOLVED_REPOS:-} " == *" $repo "* ]] && exit 22
printf 'HTTP/2 200\r\ndocker-content-digest: sha256:%s\r\n\r\n' "${repo##*/}"
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
  [ "$(jq -r '[.services[] | .state] | join(" ")' "$W/converge.json")" = "ok ok off ok" ]
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
