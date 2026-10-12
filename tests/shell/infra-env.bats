#!/usr/bin/env bats
# Testes do `infra plan|up|down <env>` com aws e terraform simulados (G8; 08,
# seção 5). Na E3 a raiz é a temporária tests/live/e3-network.

load fake_aws

setup() {
  fake_setup
  touch "$FIX/buckets/$STATE_BUCKET"
  session_json 0
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

@test "up usa a raiz temporária da E3, o state em e3/<env> e os valores do ambiente" {
  run "$REPO/infra" up dev --yes </dev/null
  [ "$status" -eq 0 ]
  terraform_calls | grep -q "terraform -chdir=$REPO/tests/live/e3-network init -input=false -reconfigure -backend-config=bucket=$STATE_BUCKET -backend-config=region=us-east-1 -backend-config=key=e3/dev/terraform.tfstate"
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

@test "falha do apply termina com código 1 e mensagem" {
  export TF_APPLY_RC=1
  # o stub trata "apply" pelo código TF_APPLY_RC
  run "$REPO/infra" up dev --yes </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"o terraform apply falhou"* ]]
}
