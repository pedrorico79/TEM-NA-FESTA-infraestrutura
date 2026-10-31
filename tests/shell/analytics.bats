#!/usr/bin/env bats
# infra analytics e infra dataset (10, seções 4 e 6; 08, seção 5) com aws,
# terraform e o pacote da Lambda simulados.

bats_require_minimum_version 1.5.0

load fake_aws

setup() {
  fake_setup
  touch "$FIX/buckets/$STATE_BUCKET"
  session_json 0
  mkdir -p "$REPO/analytics/views" "$REPO/.infra/build"
  cp "$REPO_SRC/analytics/terraform.tfvars" "$REPO/analytics/"
  cp "$REPO_SRC/analytics/views/"*.sql "$REPO/analytics/views/"
  cp "$REPO_SRC/scripts/build-dataset-lambda.sh" "$REPO/scripts/"
  # O zip da tag já existe: o build não baixa nada.
  printf 'zip' >"$REPO/.infra/build/pof-trends-v1.0.0.zip"
  export TNF_ATHENA_POLL=0

  # aws: Athena e Lambda simulados; o resto vai para o aws de fake_aws.
  mv "$BIN/aws" "$BIN/aws-base"
  fake_bin aws <<'EOF'
case "$1 $2" in
  "athena start-query-execution")
    echo "aws $*" >>"$CALLS"
    for a in "$@"; do [[ "$a" == file://* ]] && basename "${a#file://}" .sql >>"$FIX/views"; done
    echo q-1 ;;
  "athena get-query-execution")
    echo "aws $*" >>"$CALLS"
    if [[ "$*" == *StateChangeReason* ]]; then echo "erro de sintaxe"; else echo "${ATHENA_STATE:-SUCCEEDED}"; fi ;;
  "s3 cp")
    if [[ " $* " == *" --recursive "* ]]; then echo "aws $*" >>"$CALLS"; exit 0; fi
    exec "$(dirname "$0")/aws-base" "$@" ;;
  "lambda invoke")
    echo "aws $*" >>"$CALLS"
    [[ -n "${LAMBDA_ERR:-}" ]] && { echo "$LAMBDA_ERR" >&2; exit 254; }
    printf '%s' "${LAMBDA_OUT:-}" >"${@: -1}" ;;
  *) exec "$(dirname "$0")/aws-base" "$@" ;;
esac
EOF
}

OK_OUT='{"status":"ok","base":"pof_trends","data_coleta":"2026-11-02","produtos":10,"rejeicoes":0,"chaves":["s3://bucket-bronze-000000000000-us-east-1/datasets/pof_trends/bruto/data_coleta=2026-11-02/produtos_confeitaria_popularidade_mensal.csv"]}'
FALHA_OUT='{"status":"falha","base":"pof_trends","data_coleta":"2026-11-02","motivo":"[coleta externa] sem dados do Google Trends","rejeicoes":1,"chaves":["s3://b/datasets/pof_trends/rejeicoes/data_coleta=2026-11-02/rejeicoes.jsonl"]}'

@test "D4: analytics up cria o bucket de resultados, aplica com o zip da tag e cria as visões na ordem" {
  run "$REPO/infra" analytics up
  [ "$status" -eq 0 ]
  grep -q "aws s3api create-bucket --bucket tnf-athena-000000000000-us-east-1" "$CALLS"
  terraform_calls | grep -q "init .*-backend-config=bucket=tnf-tfstate-000000000000-us-east-1"
  terraform_calls | grep -q "apply -auto-approve .*-var=lambda_zip_path=$REPO/.infra/build/pof-trends-v1.0.0.zip"
  [ "$(tr '\n' ' ' <"$FIX/views")" = "vw_pof_trends_atual vw_pof_trends_sazonalidade vw_pof_trends_consumo_x_estabilidade vw_tendencias_produtos_atual " ]
  grep -q "athena start-query-execution .*--work-group tnf .*Database=tnf_bronze" "$CALLS"
}

@test "D4: com o bucket de resultados existente, analytics up não o recria" {
  touch "$FIX/buckets/tnf-athena-000000000000-us-east-1"
  run "$REPO/infra" analytics up
  [ "$status" -eq 0 ]
  run grep -q "create-bucket" "$CALLS"
  [ "$status" -ne 0 ]
}

@test "analytics plan não cria bucket nem visões" {
  run "$REPO/infra" analytics plan
  [ "$status" -eq 0 ]
  terraform_calls | grep -q " plan "
  run grep -qE "create-bucket|athena start" "$CALLS"
  [ "$status" -ne 0 ]
}

@test "analytics up com visão que falha no Athena termina com a mensagem do erro" {
  export ATHENA_STATE=FAILED
  run "$REPO/infra" analytics up
  [ "$status" -eq 1 ]
  [[ "$output" == *"a visão vw_pof_trends_atual falhou no Athena: erro de sintaxe"* ]]
}

@test "analytics sem dataset_ref é recusado antes do Terraform" {
  sed -i 's/^dataset_ref = .*/dataset_ref = ""/' "$REPO/analytics/terraform.tfvars"
  run "$REPO/infra" analytics up
  [ "$status" -eq 2 ]
  [[ "$output" == *"preencha dataset_ref em analytics/terraform.tfvars"* ]]
  [ -z "$(terraform_calls)" ]
}

@test "D5: dataset run pof-trends invoca a Lambda da EBD e mostra o resumo" {
  export LAMBDA_OUT="$OK_OUT"
  run "$REPO/infra" dataset run pof-trends
  [ "$status" -eq 0 ]
  grep -q "aws lambda invoke --function-name tnf-coleta-pof-trends --region us-east-1 .*--payload {}" "$CALLS"
  [[ "$output" == *"produtos:   10"* ]]
  [[ "$output" == *"gravado:    s3://bucket-bronze-000000000000-us-east-1/datasets/pof_trends/bruto/"* ]]
}

@test "D8: coleta interrompida termina com código 3 e mostra o motivo" {
  export LAMBDA_OUT="$FALHA_OUT"
  run "$REPO/infra" dataset run pof-trends --prazo 150
  [ "$status" -eq 3 ]
  grep -q 'payload {"prazo_segundos": 150}' "$CALLS"
  [[ "$output" == *"motivo:     [coleta externa] sem dados do Google Trends"* ]]
  [[ "$output" == *"a anterior ficou intacta"* ]]
}

@test "dataset run dev invoca a Lambda do ambiente" {
  export LAMBDA_OUT="$OK_OUT"
  run "$REPO/infra" dataset run dev
  [ "$status" -eq 0 ]
  grep -q "aws lambda invoke --function-name tnf-dev-tendencias" "$CALLS"
}

@test "dataset run de Lambda inexistente explica o que fazer" {
  export LAMBDA_ERR="An error occurred (ResourceNotFoundException)"
  run "$REPO/infra" dataset run prod
  [ "$status" -eq 2 ]
  [[ "$output" == *"não foi possível invocar tnf-prod-tendencias"*"datasets_enabled = true"* ]]
}

@test "plano B: dataset upload envia a pasta local ao mesmo prefixo do bronze" {
  mkdir -p "$BATS_TEST_TMPDIR/gerados/datasets/pof_trends/resumo/data_coleta=2026-11-02"
  run "$REPO/infra" dataset upload pof-trends "$BATS_TEST_TMPDIR/gerados"
  [ "$status" -eq 0 ]
  grep -q "aws s3 cp --recursive .* $BATS_TEST_TMPDIR/gerados/datasets/pof_trends/ s3://bucket-bronze-000000000000-us-east-1/datasets/pof_trends/" "$CALLS"
}

@test "plano B: a base dos produtos só envia a partição do ambiente pedido" {
  mkdir -p "$BATS_TEST_TMPDIR/gerados/datasets/tendencias_produtos"
  run "$REPO/infra" dataset upload dev "$BATS_TEST_TMPDIR/gerados"
  [ "$status" -eq 0 ]
  grep -q -- '--include \*env=dev/\*' "$CALLS"
}

@test "dataset com alvo desconhecido é recusado" {
  run "$REPO/infra" dataset run staging
  [ "$status" -eq 2 ]
  [[ "$output" == *"informe pof-trends, dev ou prod"* ]]
}
