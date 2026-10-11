#!/usr/bin/env bats
# Testes do `infra bootstrap` com aws e terraform simulados (G5 e G16 na parte
# offline; a conferência real é feita no laboratório).

load fake_aws

setup() {
  fake_setup
  session_json 0
}

bootstrap() {
  run "$REPO/infra" bootstrap
}

@test "conta nova: cria os buckets com state local e migra para o bucket de state" {
  export TF_PLAN_RC=2
  bootstrap </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"state:  $STATE_BUCKET (será criado)"* ]]
  terraform_calls | grep -q " apply "
  terraform_calls | grep -q "init -input=false -migrate-state -force-copy -backend-config=bucket=$STATE_BUCKET"
  ! terraform_calls | grep -q " import "
  [ ! -f "$REPO/bootstrap/backend_override.tf" ]
  [[ "$output" == *"bootstrap concluído"* ]]
}

@test "conta nova: buckets novos são criados sem pedir confirmação" {
  export TF_PLAN_RC=2
  bootstrap </dev/null
  [[ "$output" != *"Aplicar o plano?"* ]]
}

@test "G16: bronze existente é importado; a diferença pede confirmação e N não aplica nada" {
  touch "$FIX/buckets/$BRONZE_BUCKET"
  export TF_PLAN_RC=2
  bootstrap <<<"N"
  [ "$status" -eq 2 ]
  terraform_calls | grep -q "import -input=false aws_s3_bucket.bronze $BRONZE_BUCKET"
  [[ "$output" == *"os objetos não são tocados"* ]]
  [[ "$output" == *"Aplicar o plano?"* ]]
  ! terraform_calls | grep -q " apply "
  ! grep -Eq '^aws s3 (rm|rb)|delete-object|delete-bucket' "$CALLS"
}

@test "G16: com s, aplica o plano do bronze importado" {
  touch "$FIX/buckets/$BRONZE_BUCKET"
  export TF_PLAN_RC=2
  bootstrap <<<"s"
  [ "$status" -eq 0 ]
  terraform_calls | grep -q " apply "
}

@test "G5 e G16: na segunda execução, com os dois buckets no state, nada é alterado" {
  touch "$FIX/buckets/$STATE_BUCKET" "$FIX/buckets/$BRONZE_BUCKET"
  printf 'aws_s3_bucket.bronze\naws_s3_bucket.state\n' >"$FIX/tf-state-list"
  export TF_PLAN_RC=0
  bootstrap </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"nada a alterar"* ]]
  ! terraform_calls | grep -q " import "
  ! terraform_calls | grep -q " apply "
  terraform_calls | grep -q "init -input=false -reconfigure -backend-config=bucket=$STATE_BUCKET"
}

@test "state perdido: os dois buckets existem mas não estão no state e são importados" {
  touch "$FIX/buckets/$STATE_BUCKET" "$FIX/buckets/$BRONZE_BUCKET"
  export TF_PLAN_RC=0
  bootstrap </dev/null
  [ "$status" -eq 0 ]
  terraform_calls | grep -q "import -input=false aws_s3_bucket.state $STATE_BUCKET"
  terraform_calls | grep -q "import -input=false aws_s3_bucket.bronze $BRONZE_BUCKET"
}

@test "G7: credenciais inválidas param o bootstrap antes de qualquer chamada ao terraform" {
  export AWS_STS=fail
  bootstrap </dev/null
  [ "$status" -eq 2 ]
  [ -z "$(terraform_calls)" ]
}
