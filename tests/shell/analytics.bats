#!/usr/bin/env bats
# infra analytics e infra dataset (10, seções 4 e 6; 08, seção 5) com aws e
# terraform simulados. Desde a DA8 (19/11/2026) a camada analytics não tem
# Lambda: só catálogo, workgroup e visões; as coletas são as dos ambientes.

bats_require_minimum_version 1.5.0

load fake_aws

setup() {
  fake_setup
  touch "$FIX/buckets/$STATE_BUCKET"
  session_json 0
  mkdir -p "$REPO/analytics/views"
  cp "$REPO_SRC/analytics/terraform.tfvars" "$REPO/analytics/"
  cp "$REPO_SRC/analytics/views/"*.sql "$REPO/analytics/views/"
  export TNF_ATHENA_POLL=0

  # aws: Athena e Lambda simulados; o resto vai para o aws de fake_aws. Cada
  # instrução do Athena fica em $FIX/athena como "CREATE <visão>" ou "DROP <visão>".
  mv "$BIN/aws" "$BIN/aws-base"
  fake_bin aws <<'EOF'
case "$1 $2" in
  "athena start-query-execution")
    echo "aws $*" >>"$CALLS"
    prev=""
    for a in "$@"; do
      if [[ "$prev" == --query-string ]]; then
        if [[ "$a" =~ CREATE\ OR\ REPLACE\ VIEW\ ([a-z_]+) ]]; then echo "CREATE ${BASH_REMATCH[1]}" >>"$FIX/athena"
        elif [[ "$a" =~ DROP\ VIEW\ IF\ EXISTS\ ([a-z_]+) ]]; then echo "DROP ${BASH_REMATCH[1]}" >>"$FIX/athena"
        else echo "OUTRA" >>"$FIX/athena"; fi
      fi
      prev="$a"
    done
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

OK_OUT='{"status":"ok","base":"tendencias_produtos","data_coleta":"2026-11-02","produtos":8,"rejeicoes":0,"chaves":["s3://bucket-bronze-000000000000-us-east-1/datasets/tendencias_produtos/bruto/env=dev/data_coleta=2026-11-02/tendencias_produtos_sistema.csv"]}'
FALHA_OUT='{"status":"falha","base":"tendencias_produtos","data_coleta":"2026-11-02","motivo":"[coleta externa] sem dados do Google Trends","rejeicoes":1,"chaves":["s3://b/datasets/tendencias_produtos/rejeicoes/env=dev/data_coleta=2026-11-02/rejeicoes.jsonl"]}'

@test "D4: analytics up cria o bucket de resultados, aplica, remove as visões da POF e cria a dos produtos" {
  run "$REPO/infra" analytics up
  [ "$status" -eq 0 ]
  grep -q "aws s3api create-bucket --bucket tnf-athena-000000000000-us-east-1" "$CALLS"
  terraform_calls | grep -q "init .*-backend-config=bucket=tnf-tfstate-000000000000-us-east-1"
  terraform_calls | grep -q "apply -auto-approve "
  [ -z "$(terraform_calls | grep lambda_zip_path)" ]
  [ "$(tr '\n' ' ' <"$FIX/athena")" = "DROP vw_pof_trends_consumo_x_estabilidade DROP vw_pof_trends_sazonalidade DROP vw_pof_trends_atual CREATE vw_tendencias_produtos_atual " ]
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

@test "analytics up com instrução que falha no Athena termina com a mensagem do erro" {
  export ATHENA_STATE=FAILED
  run "$REPO/infra" analytics up
  [ "$status" -eq 1 ]
  [[ "$output" == *"a instrução Athena falhou: erro de sintaxe"* ]]
}

@test "D5: dataset run dev invoca a Lambda do ambiente e mostra o resumo" {
  export LAMBDA_OUT="$OK_OUT"
  run "$REPO/infra" dataset run dev
  [ "$status" -eq 0 ]
  grep -q "aws lambda invoke --function-name tnf-dev-tendencias .*--payload {}" "$CALLS"
  [[ "$output" == *"produtos:   8"* ]]
  [[ "$output" == *"gravado:    s3://bucket-bronze-000000000000-us-east-1/datasets/tendencias_produtos/bruto/env=dev/"* ]]
}

@test "D8: coleta interrompida termina com código 3 e mostra o motivo" {
  export LAMBDA_OUT="$FALHA_OUT"
  run "$REPO/infra" dataset run dev --prazo 150
  [ "$status" -eq 3 ]
  grep -q 'payload {"prazo_segundos": 150}' "$CALLS"
  [[ "$output" == *"motivo:     [coleta externa] sem dados do Google Trends"* ]]
  [[ "$output" == *"a anterior ficou intacta"* ]]
}

@test "dataset run de Lambda inexistente explica o que fazer" {
  export LAMBDA_ERR="An error occurred (ResourceNotFoundException)"
  run "$REPO/infra" dataset run prod
  [ "$status" -eq 2 ]
  [[ "$output" == *"não foi possível invocar tnf-prod-tendencias"*"datasets_enabled = true"* ]]
}

@test "plano B: dataset upload envia só a partição do ambiente pedido ao prefixo do bronze" {
  mkdir -p "$BATS_TEST_TMPDIR/gerados/datasets/tendencias_produtos"
  run "$REPO/infra" dataset upload dev "$BATS_TEST_TMPDIR/gerados"
  [ "$status" -eq 0 ]
  grep -q -- '--include \*env=dev/\*' "$CALLS"
  grep -q "aws s3 cp --recursive .* $BATS_TEST_TMPDIR/gerados/datasets/tendencias_produtos/ s3://bucket-bronze-000000000000-us-east-1/datasets/tendencias_produtos/" "$CALLS"
}

@test "a base POF retirada (DA8) é recusada como alvo" {
  run "$REPO/infra" dataset run pof-trends
  [ "$status" -eq 2 ]
  [[ "$output" == *"informe dev ou prod"* ]]
}

@test "dataset com alvo desconhecido é recusado" {
  run "$REPO/infra" dataset run staging
  [ "$status" -eq 2 ]
  [[ "$output" == *"informe dev ou prod"* ]]
}
