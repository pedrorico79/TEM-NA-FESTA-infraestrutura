#!/usr/bin/env bats
# Testes do `infra bootstrap` com aws e terraform simulados (G5, G7 e G16 na
# parte offline; a conferência real é feita no laboratório). Os buckets são
# criados pelo AWS CLI e o Terraform gerencia só a configuração (08, H20).

load fake_aws

setup() {
  fake_setup
  session_json 0
}

bootstrap() {
  run "$REPO/infra" bootstrap
}

@test "conta nova: cria os dois buckets com o AWS CLI, com as etiquetas, e aplica a configuração sem perguntar" {
  export TF_PLAN_RC=2
  bootstrap </dev/null
  [ "$status" -eq 0 ]
  grep -q "aws s3api create-bucket --bucket $STATE_BUCKET --region us-east-1" "$CALLS"
  grep -q "aws s3api create-bucket --bucket $BRONZE_BUCKET --region us-east-1" "$CALLS"
  grep -q "put-bucket-tagging --bucket $STATE_BUCKET.*Key=ManagedBy,Value=terraform" "$CALLS"
  [[ "$output" != *"Aplicar o plano?"* ]]
  terraform_calls | grep -q "init -input=false -reconfigure -backend-config=bucket=$STATE_BUCKET -backend-config=region=us-east-1"
  terraform_calls | grep -q " apply "
  ! terraform_calls | grep -Eq " import | -migrate-state"
  [[ "$output" == *"bootstrap concluído"* ]]
}

@test "bronze em outra região é criado com LocationConstraint" {
  sed -i 's/^bronze_bucket_region = .*/bronze_bucket_region = "us-west-2"/' "$REPO/bootstrap/terraform.tfvars"
  export TF_PLAN_RC=2
  bootstrap </dev/null
  [ "$status" -eq 0 ]
  grep -q "create-bucket --bucket bucket-bronze-000000000000-us-west-2 --region us-west-2 --create-bucket-configuration LocationConstraint=us-west-2" "$CALLS"
}

@test "G16: bronze existente é adotado sem ser recriado; a mudança pede confirmação e N não aplica nada" {
  touch "$FIX/buckets/$BRONZE_BUCKET"
  export TF_PLAN_RC=2
  bootstrap <<<"N"
  [ "$status" -eq 2 ]
  [[ "$output" == *"bronze: $BRONZE_BUCKET (já existe; os objetos não são tocados)"* ]]
  ! grep -q "create-bucket --bucket $BRONZE_BUCKET" "$CALLS"
  [[ "$output" == *"Aplicar o plano?"* ]]
  ! terraform_calls | grep -q " apply "
  ! grep -Eiq 's3 (rm|rb|mv)|delete' "$CALLS"
}

@test "G16: com s, aplica a configuração no bronze adotado" {
  touch "$FIX/buckets/$BRONZE_BUCKET"
  export TF_PLAN_RC=2
  bootstrap <<<"s"
  [ "$status" -eq 0 ]
  terraform_calls | grep -q " apply "
}

@test "G5: na segunda execução nada é criado nem alterado" {
  touch "$FIX/buckets/$STATE_BUCKET" "$FIX/buckets/$BRONZE_BUCKET"
  export TF_PLAN_RC=0
  bootstrap </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"nada a alterar"* ]]
  ! grep -q "create-bucket" "$CALLS"
  ! terraform_calls | grep -q " apply "
}

@test "falha no apply termina com código 1 e diz que os buckets continuam existindo" {
  export TF_PLAN_RC=2 TF_APPLY_RC=1
  bootstrap </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"Os buckets continuam existindo"* ]]
  [ ! -f "$REPO/.infra/bootstrap.tfplan" ]
}

@test "G7: credenciais inválidas param o bootstrap antes de qualquer chamada ao terraform" {
  export AWS_STS=fail
  bootstrap </dev/null
  [ "$status" -eq 2 ]
  [ -z "$(terraform_calls)" ]
  ! grep -q "create-bucket" "$CALLS"
}
