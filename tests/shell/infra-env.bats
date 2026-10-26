#!/usr/bin/env bats
# Testes do `infra plan|up|down <env>` com aws e terraform simulados (G8; 08,
# seção 5). Na E3 a raiz é a temporária tests/live/e3-network.

load fake_aws

setup() {
  fake_setup
  touch "$FIX/buckets/$STATE_BUCKET"
  session_json 0
  env_ready dev
  env_ready prod
  export TNF_WAIT_INTERVAL=0 TNF_WAIT_TIMEOUT=0
}

@test "G8: infra down prod sem digitar o nome do ambiente não destrói nada e não chama o terraform" {
  run "$REPO/infra" down prod <<<"s"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Para DESTRUIR o ambiente prod, digite o nome dele"* ]]
  [[ "$output" == *"nada foi feito"* ]]
  [ -z "$(terraform_calls)" ]
}

@test "G8: digitando o nome, infra down prod segue e destrói" {
  run "$REPO/infra" down prod <<<"prod"
  [ "$status" -eq 0 ]
  terraform_calls | grep -q "destroy -auto-approve -input=false -var-file=$REPO/envs/prod/terraform.tfvars"
}

@test "G8: --yes não dispensa a confirmação em prod" {
  run "$REPO/infra" down prod --yes <<<""
  [ "$status" -eq 2 ]
  [[ "$output" == *"--yes não dispensa a confirmação em prod"* ]]
  [ -z "$(terraform_calls)" ]
}

@test "G8: --yes dispensa a confirmação em dev" {
  run "$REPO/infra" down dev --yes </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" != *"digite o nome"* ]]
  terraform_calls | grep -q "destroy -auto-approve"
}

@test "G8: sem --yes, dev também pede o nome digitado" {
  run "$REPO/infra" down dev <<<"prod"
  [ "$status" -eq 2 ]
  [ -z "$(terraform_calls)" ]
}

@test "G8: infra up prod pede o nome digitado; --yes não dispensa" {
  run "$REPO/infra" up prod --yes <<<"x"
  [ "$status" -eq 2 ]
  [ -z "$(terraform_calls)" ]
  run "$REPO/infra" up prod <<<"prod"
  [ "$status" -eq 0 ]
  terraform_calls | grep -q "apply -auto-approve"
}

@test "up usa a raiz envs/<env>, o state em envs/<env> e os valores do ambiente" {
  run "$REPO/infra" up dev --yes </dev/null
  [ "$status" -eq 0 ]
  terraform_calls | grep -q "terraform -chdir=$REPO/envs/dev init -input=false -reconfigure -backend-config=bucket=$STATE_BUCKET -backend-config=region=us-east-1 -backend-config=key=envs/dev/terraform.tfstate"
  terraform_calls | grep -q "apply -auto-approve -input=false -var-file=$REPO/envs/dev/terraform.tfvars"
}

@test "plan não pede confirmação e não aplica nada" {
  run "$REPO/infra" plan prod </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" != *"digite o nome"* ]]
  terraform_calls | grep -q " plan -input=false"
  ! terraform_calls | grep -Eq "apply|destroy"
}

@test "G7: infra up staging é recusado com código 2 antes de qualquer chamada ao terraform" {
  run "$REPO/infra" up staging
  [ "$status" -eq 2 ]
  [[ "$output" == *"ambiente 'staging' desconhecido"* ]]
  [ -z "$(terraform_calls)" ]
}

@test "up detecta o IP, cria o bucket de artefatos, aplica e espera o ambiente ficar pronto" {
  run "$REPO/infra" up dev --yes </dev/null
  [ "$status" -eq 0 ]
  grep -q "curl .*checkip.amazonaws.com" "$CALLS"
  grep -q "aws s3api create-bucket --bucket tnf-dev-artifacts-000000000000-us-east-1" "$CALLS"
  terraform_calls | grep -q 'apply -auto-approve .*-var=admin_ssh_cidrs=\["203.0.113.10/32"\]'
  [[ "$output" == *"ambiente dev pronto"* ]]
  [[ "$output" == *"Bastion: 203.0.113.5"* ]]
}

@test "up confere o ALB ao fim e imprime o endereço do sistema" {
  export FAKE_ALB=tem-na-festa-dev-alb-1.us-east-1.elb.amazonaws.com
  run "$REPO/infra" up dev --yes </dev/null
  [ "$status" -eq 0 ]
  grep -q "curl .*http://$FAKE_ALB/" "$CALLS"
  [[ "$output" == *"o ALB respondeu 200 em /"* ]]
  [[ "$output" == *"Sistema: http://$FAKE_ALB/"* ]]
}

@test "up termina com código 3 quando o ALB não responde 200" {
  export FAKE_ALB=tem-na-festa-dev-alb-1.us-east-1.elb.amazonaws.com FAKE_HTTP_CODE=502 TNF_ALB_TIMEOUT=0
  run "$REPO/infra" up dev --yes </dev/null
  [ "$status" -eq 3 ]
  [[ "$output" == *"o ALB não respondeu 200 em / (última resposta: 502)"* ]]
  [[ "$output" == *"docker service ps tnf-web_frontend"* ]]
}

@test "up avisa quando o IP autorizado no bastion vai mudar" {
  echo '["198.51.100.20/32"]' >"$FIX/tf-admin-cidrs.json"
  run "$REPO/infra" up dev --yes </dev/null
  [[ "$output" == *"o IP autorizado no bastion mudará de 198.51.100.20/32 para 203.0.113.10/32"* ]]
}

@test "up com admin_ssh_cidrs preenchida não passa o IP detectado" {
  echo 'admin_ssh_cidrs = ["198.51.100.0/24"]' >>"$REPO/envs/dev/terraform.tfvars"
  run "$REPO/infra" up dev --yes </dev/null
  [ "$status" -eq 0 ]
  ! terraform_calls | grep -q -- "-var=admin_ssh_cidrs"
}

@test "plan sem IP detectável pede --ip e não chama o plan" {
  export FAKE_IP=""
  run "$REPO/infra" plan dev </dev/null
  [ "$status" -eq 2 ]
  [[ "$output" == *"Informe-o com --ip <ip>"* ]]
  ! terraform_calls | grep -q " plan "
}

@test "up espera e termina com código 3 quando um nó falha" {
  echo '{"state":"failed","step":"docker","message":"pacote não baixou"}' >"$FIX/s3/tnf-dev-artifacts-000000000000-us-east-1/status/nodes/tem-na-festa-dev-web-1.json"
  run "$REPO/infra" up dev --yes </dev/null
  [ "$status" -eq 3 ]
  [[ "$output" == *"o nó tem-na-festa-dev-web-1 falhou na etapa docker"* ]]
  [[ "$output" == *"infra ssh dev web-1"* ]]
}

@test "S6: nó sem nenhum status (sem saída pela NAT) vira falha com mensagem clara, sem travar" {
  rm "$FIX/s3/tnf-dev-artifacts-000000000000-us-east-1/status/nodes/tem-na-festa-dev-web-1.json"
  export TNF_WAIT_SILENT=0
  run "$REPO/infra" up dev --yes </dev/null
  [ "$status" -eq 3 ]
  [[ "$output" == *"o nó tem-na-festa-dev-web-1 não deu nenhum sinal"*"rota da NAT"* ]]
}

@test "down apaga as chaves de host conhecidas do ambiente (os IPs fixos voltam com chaves novas)" {
  mkdir -p "$REPO/.infra"
  echo "10.0.3.10 ssh-ed25519 AAAAantiga" >"$REPO/.infra/known_hosts_dev"
  run "$REPO/infra" down dev --yes </dev/null
  [ "$status" -eq 0 ]
  [ ! -f "$REPO/.infra/known_hosts_dev" ]
}

@test "down apaga o bucket de artefatos depois do destroy" {
  touch "$FIX/buckets/tnf-dev-artifacts-000000000000-us-east-1"
  run "$REPO/infra" down dev --yes </dev/null
  [ "$status" -eq 0 ]
  grep -q "aws s3 rb s3://tnf-dev-artifacts-000000000000-us-east-1 --force" "$CALLS"
}

@test "infra status mostra os nós e a convergência" {
  mkdir -p "$FIX/s3/tnf-dev-artifacts-000000000000-us-east-1"
  echo 'EXPECTED_NODES=tem-na-festa-dev-web-1,tem-na-festa-dev-app-1' >"$FIX/s3/tnf-dev-artifacts-000000000000-us-east-1/stack.env"
  run "$REPO/infra" status dev
  [ "$status" -eq 0 ]
  [[ "$output" == *"tem-na-festa-dev-app-1"*"joined"* ]]
  [[ "$output" == *"tem-na-festa-dev-bastion"*"ready"* ]]
  [[ "$output" == *"convergência"*"ready"* ]]
}

@test "infra status mostra cada serviço com réplicas e imagem, e a mensageria desligada" {
  local b="$FIX/s3/tnf-dev-artifacts-000000000000-us-east-1"
  echo 'EXPECTED_NODES=tem-na-festa-dev-web-1,tem-na-festa-dev-app-1' >"$b/stack.env"
  echo '{"state":"ready","message":"ok","services":{"backend":{"state":"ok","desired":1,"running":1,"image":"ns/tnf-backend:dev@sha256:abc"},"messaging":{"state":"off","desired":0,"running":0,"image":""}}}' >"$b/status/converge.json"
  run "$REPO/infra" status dev
  [ "$status" -eq 0 ]
  [[ "$output" == *"serviço backend"*"ok"*"1/1 ns/tnf-backend:dev@sha256:abc"* ]]
  [[ "$output" == *"serviço messaging"*"off"*"desligado"* ]]
}

@test "falha do apply termina com código 1 e mensagem" {
  export TF_APPLY_RC=1
  # o stub trata "apply" pelo código TF_APPLY_RC
  run "$REPO/infra" up dev --yes </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"o terraform apply falhou"* ]]
}
