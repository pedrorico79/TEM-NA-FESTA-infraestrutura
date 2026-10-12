#!/usr/bin/env bats
# Testes do scripts/preflight.sh (08, seções 5.3 e 5.4): G7, G19, G21, G22 e
# o lock órfão. aws e terraform são simulados (fake_aws.bash).

load fake_aws

setup() {
  fake_setup
  touch "$FIX/buckets/$STATE_BUCKET"
  session_json 0 # sessão recém-vista: 240 min estimados
}

preflight() {
  run "$REPO/scripts/preflight.sh" "$@"
}

# --- G7 -------------------------------------------------------------------------

@test "G7: ambiente desconhecido é recusado com a mensagem de T1, código 2, sem chamar o terraform" {
  preflight up staging
  [ "$status" -eq 2 ]
  [[ "$output" == *"ambiente 'staging' desconhecido: apenas dev ou prod"* ]]
  [ -z "$(terraform_calls)" ]
  [ -z "$(cat "$CALLS")" ]
}

@test "G7: credenciais ausentes ou inválidas terminam com código 2 e mensagem em português, sem chamar o terraform" {
  export AWS_STS=fail
  local op
  for op in plan up down; do
    preflight "$op" dev
    [ "$status" -eq 2 ]
    [[ "$output" == *"credenciais da AWS ausentes, inválidas ou vencidas"* ]]
  done
  preflight bootstrap
  [ "$status" -eq 2 ]
  [ -z "$(terraform_calls)" ]
}

@test "sem o bucket de state, plan, up e down mandam rodar infra bootstrap" {
  rm "$FIX/buckets/$STATE_BUCKET"
  preflight up dev
  [ "$status" -eq 2 ]
  [[ "$output" == *"Rode 'infra bootstrap' uma vez nesta conta"* ]]
}

@test "com tudo limpo, as pré-checagens passam sem chamar o terraform" {
  preflight up dev
  [ "$status" -eq 0 ]
  [ -z "$(terraform_calls)" ]
}

# --- G21 ------------------------------------------------------------------------

@test "G21: com 15 minutos informados, up avisa e pede confirmação; N cancela com código 2" {
  session_json 0 15 0
  preflight up dev <<<"N"
  [ "$status" -eq 2 ]
  [[ "$output" == *"restam cerca de 15 minuto(s) da sessão do laboratório"* ]]
  [[ "$output" == *"operação cancelada"* ]]
}

@test "G21: com 15 minutos, responder s continua; --yes não pula o aviso" {
  session_json 0 15 0
  preflight down dev --yes <<<"s"
  [ "$status" -eq 0 ]
  [[ "$output" == *"restam cerca de 15 minuto(s)"* ]]
  [[ "$output" == *"Continuar mesmo assim?"* ]]
}

@test "G21: com 60 minutos informados não avisa" {
  session_json 0 60 0
  preflight up dev </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" != *"restam cerca"* ]]
}

@test "G21: sem informar o tempo, o aviso diz que é uma estimativa" {
  session_json $((230 * 60))
  preflight bootstrap <<<"N"
  [ "$status" -eq 2 ]
  [[ "$output" == *"pela estimativa, restam cerca de 10 minuto(s)"* ]]
  [[ "$output" == *"infra session <minutos>"* ]]
}

@test "G21: plan não pede confirmação de sessão" {
  session_json 0 15 0
  preflight plan dev </dev/null
  [ "$status" -eq 0 ]
}

@test "G21: infra session registra os minutos e mostra o que resta" {
  run "$REPO/infra" session 90
  [ "$status" -eq 0 ]
  [[ "$output" == *"Restam cerca de 90 minuto(s) da sessão do laboratório (pelo valor informado)."* ]]
  run "$REPO/infra" session
  [[ "$output" == *"Restam cerca de 90 minuto(s)"* ]]
  run grep -c "$AWS_TOKEN" "$REPO/.infra/session.json"
  [ "$output" -eq 0 ]
  run "$REPO/infra" session 0
  [ "$status" -eq 2 ]
}

@test "G21: um token novo (outra sessão) recomeça a estimativa" {
  session_json 0 15 0
  export AWS_TOKEN="outro-token"
  run "$REPO/infra" session
  [[ "$output" == *"Restam cerca de 240 minuto(s)"*"estimativa"* ]]
}

# --- G19 ------------------------------------------------------------------------

errored() { echo "{\"version\":4,\"serial\":$1,\"lineage\":\"x\"}" >"$REPO/tests/live/e3-network/errored.tfstate"; }
remote() { echo "{\"version\":4,\"serial\":$1,\"lineage\":\"x\"}" >"$FIX/tf-remote.tfstate"; }

@test "G19: com errored.tfstate e credenciais vencidas, recusa com código 2 antes do terraform" {
  errored 5
  export AWS_STS=fail
  preflight up dev
  [ "$status" -eq 2 ]
  [ -z "$(terraform_calls)" ]
  [ -f "$REPO/tests/live/e3-network/errored.tfstate" ]
}

@test "G19: com credenciais válidas oferece o state push; N não envia e preserva o arquivo" {
  errored 5
  remote 4
  preflight up dev <<<"N"
  [ "$status" -eq 2 ]
  [[ "$output" == *"serial) do arquivo local: 5; do state remoto: 4"* ]]
  [[ "$output" == *"nada foi enviado"* ]]
  ! terraform_calls | grep -q "state push"
  [ -f "$REPO/tests/live/e3-network/errored.tfstate" ]
}

@test "G19: com s, envia sem -force, arquiva em .infra/recovered e roda o plan" {
  errored 5
  remote 4
  preflight up dev <<<"s"
  [ "$status" -eq 0 ]
  terraform_calls | grep -q "state push errored.tfstate"
  ! terraform_calls | grep -q -- "-force"
  [ ! -f "$REPO/tests/live/e3-network/errored.tfstate" ]
  ls "$REPO"/.infra/recovered/dev-*.tfstate
  terraform_calls | grep -q " plan "
}

@test "G19: se o state remoto for mais novo, não envia e preserva o arquivo" {
  errored 5
  remote 7
  preflight down dev <<<"s"
  [ "$status" -eq 2 ]
  [[ "$output" == *"o state remoto é mais novo"* ]]
  ! terraform_calls | grep -q "state push"
  [ -f "$REPO/tests/live/e3-network/errored.tfstate" ]
}

# --- lock órfão (08, seção 5.3) ----------------------------------------------------

lock() {
  mkdir -p "$FIX/s3/$STATE_BUCKET/e3/dev"
  printf '{"ID":"lock-123","Operation":"OperationTypeApply","Who":"%s","Created":"%s"}\n' \
    "$1" "$(date -u -d "-$2 minutes" +%Y-%m-%dT%H:%M:%SZ)" >"$FIX/s3/$STATE_BUCKET/e3/dev/terraform.tfstate.tflock"
}

@test "lock órfão: mostra quem, quando, operação e ID; sem digitar o ambiente nada é destravado" {
  lock "aluno@maquina-teste" 30
  preflight up dev <<<"s"
  [ "$status" -eq 2 ]
  [[ "$output" == *"quem:     aluno@maquina-teste"* ]]
  [[ "$output" == *"operação: OperationTypeApply"* ]]
  [[ "$output" == *"ID:       lock-123"* ]]
  [[ "$output" == *"nada foi destravado"* ]]
  ! terraform_calls | grep -q "force-unlock"
}

@test "lock órfão: lock recente ou de outra máquina recebe destaque" {
  lock "colega@outra-maquina" 3
  preflight up dev <<<""
  [[ "$output" == *"criado há menos de 10 minutos"* ]]
  [[ "$output" == *"criado por outra máquina"* ]]
}

@test "lock órfão: digitando o nome do ambiente, destrava, roda o plan e pede para repetir" {
  lock "aluno@maquina-teste" 30
  preflight up dev <<<"dev"
  [ "$status" -eq 2 ]
  terraform_calls | grep -q "force-unlock -force lock-123"
  terraform_calls | grep -q " plan "
  [[ "$output" == *"repita 'infra up dev'"* ]]
}

# --- G22 ------------------------------------------------------------------------

stack_env() {
  local b="tnf-dev-artifacts-000000000000-us-east-1"
  mkdir -p "$FIX/s3/$b"
  printf 'EXPECTED_NODES=tem-na-festa-dev-web-1,tem-na-festa-dev-app-1\nMANAGER_COUNT=%s\n' "$1" >"$FIX/s3/$b/stack.env"
}

@test "G22: manager_count diferente do aplicado é recusado no up, com código 2 e o caminho" {
  stack_env 1
  sed -i 's/^manager_count .*/manager_count   = 3/' "$REPO/envs/dev/terraform.tfvars"
  preflight up dev
  [ "$status" -eq 2 ]
  [[ "$output" == *"manager_count em vigor no ambiente dev é 1, e o terraform.tfvars pede 3"* ]]
  [[ "$output" == *"infra down dev e infra up dev"* ]]
  [ -z "$(terraform_calls)" ]
}

@test "G22: o down não é afetado pela mudança de manager_count" {
  stack_env 1
  sed -i 's/^manager_count .*/manager_count   = 3/' "$REPO/envs/dev/terraform.tfvars"
  preflight down dev
  [ "$status" -eq 0 ]
}

@test "G22: com manager_count igual ao aplicado, passa" {
  stack_env 1
  preflight up dev
  [ "$status" -eq 0 ]
}

@test "G22: ambiente novo (sem stack.env) passa em silêncio" {
  sed -i 's/^manager_count .*/manager_count   = 3/' "$REPO/envs/dev/terraform.tfvars"
  preflight up dev
  [ "$status" -eq 0 ]
  [[ "$output" != *"manager_count"* ]]
}
