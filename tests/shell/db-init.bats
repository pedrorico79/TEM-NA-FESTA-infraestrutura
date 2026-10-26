#!/usr/bin/env bats
# Testes do node/db-init.sh (04, seção 7, passo 6; 05, A4 e B5) com mysql,
# aws e curl simulados. O "banco" é um arquivo com o número de tabelas.

DB_INIT="$BATS_TEST_DIRNAME/../../node/db-init.sh"

setup() {
  W="$BATS_TEST_TMPDIR"
  BIN="$W/bin"
  mkdir -p "$BIN" "$W/s3" "$W/run"
  export CALLS="$W/calls" TABLES="$W/tables" MARKER_FILE="$W/s3/db-init.json"
  : >"$CALLS"
  echo 0 >"$TABLES"
  export TNF_RUN_DIR="$W/run" TNF_DB_INIT_LOG="$W/db-init.log" TNF_NODE_ENV="$W/node.env"
  cat >"$TNF_NODE_ENV" <<'EOF'
TNF_ENV=dev
TNF_REGION=us-east-1
TNF_ARTIFACTS_BUCKET=artefatos
EOF
  cat >"$W/stack.env" <<'EOF'
DB_ENDPOINT=banco.exemplo.invalid
DB_NAME=tem_na_festa
DB_SCHEMA_REPO_URL=https://github.com/exemplo/schema
DB_SCHEMA_REF=v1.0.0
DB_SCHEMA_PATH=schema.sql
EOF

  stub aws <<'EOF'
echo "aws $*" >>"$CALLS"
case "$1 $2" in
  "s3 cp")
    if [[ "$3" == s3://* ]]; then [[ -f "$MARKER_FILE" ]] && cat "$MARKER_FILE" || exit 1
    else cat >"$MARKER_FILE"; fi ;;
  "rds describe-db-instances") echo tnf_admin ;;
  "ssm get-parameter") echo SenhaDeTeste123 ;;
esac
EOF
  # mysql: SELECT COUNT conta as tabelas; o script "falha" se SCRIPT_FAIL=1;
  # DROP TABLE zera o banco; o resto só é registrado.
  stub mysql <<'EOF'
input=""
if [[ "$*" != *" -e "* ]]; then input="$(cat)"; fi
echo "mysql $* :: $input" >>"$CALLS"
case "$*" in
  *"SELECT 1"*) exit 0 ;;
  *"COUNT(*)"*) cat "$TABLES"; exit 0 ;;
  *"DROP TRIGGER"*) [[ "$(cat "$TABLES")" -gt 0 ]] && echo 'DROP TABLE IF EXISTS `t`;'; exit 0 ;;
esac
if [[ "$input" == *"DROP TABLE"* ]]; then echo 0 >"$TABLES"; exit 0; fi
if [[ "$input" == *"CREATE TABLE"* ]]; then
  echo 1 >"$TABLES"
  if [[ "${SCRIPT_FAIL:-0}" == 1 ]]; then echo "ERROR 1064 (42000) at line 2: erro de sintaxe" >&2; exit 1; fi
fi
exit 0
EOF
  stub curl <<'EOF'
echo "curl $*" >>"$CALLS"
[[ "${DOWNLOAD_FAIL:-0}" == 1 ]] && exit 22
out=""; while [[ $# -gt 0 ]]; do [[ "$1" == -o ]] && out="$2"; shift; done
printf 'CREATE TABLE usuario (id INT);\nINSERT INTO usuario VALUES (1);\n' >"$out"
EOF
  stub sleep <<'EOF'
exit 0
EOF
  export PATH="$BIN:$PATH"
}

stub() {
  { printf '#!%s\n' "$(command -v bash)"; cat; } >"$BIN/$1"
  chmod +x "$BIN/$1"
}

db_init() { run "$DB_INIT" "$W/stack.env" "${1:-hash-1}"; }
marker() { jq -r ".$1" "$MARKER_FILE"; }

@test "banco vazio: baixa da tag, aplica, cria o tnf_app sem DROP e grava done" {
  db_init
  [ "$status" -eq 0 ]
  [ "$output" = ok ]
  grep -q 'curl .*https://raw.githubusercontent.com/exemplo/schema/v1.0.0/schema.sql' "$CALLS"
  [ "$(marker schema)" = applied ]
  [ "$(marker state)" = done ]
  grep -q "GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, INDEX, REFERENCES ON \`tem_na_festa\`.\* TO 'tnf_app'@'%'" "$CALLS"
  grep -q "REVOKE ALL PRIVILEGES, GRANT OPTION FROM 'tnf_app'" "$CALLS"
  ! grep -q 'GRANT .*DROP' "$CALLS"
}

@test "a senha nunca vai na linha de comando do mysql" {
  db_init
  ! grep -E '^mysql [^:]*SenhaDeTeste123' "$CALLS"
  [ -z "$(ls "$W/run")" ]
}

@test "done: não faz nada" {
  echo '{"state":"done","schema":"applied"}' >"$MARKER_FILE"
  db_init
  [ "$status" -eq 0 ]
  [ "$output" = ok ]
  ! grep -q '^mysql' "$CALLS"
}

@test "Q24 (a): script que falha no meio limpa o schema, grava failed e devolve a mensagem" {
  export SCRIPT_FAIL=1
  db_init
  [ "$status" -eq 0 ]
  [[ "$output" == "failed o script do schema (v1.0.0) falhou:"*"erro de sintaxe"*"O schema foi limpo"* ]]
  [ "$(cat "$TABLES")" = 0 ]
  [ "$(marker schema)" = failed ]
  [ "$(marker attempts)" = 1 ]
}

@test "Q24 (b): failed com o mesmo hash não tenta de novo" {
  export SCRIPT_FAIL=1
  db_init hash-1
  : >"$CALLS"
  db_init hash-1
  [ "$status" -eq 0 ]
  [[ "$output" == failed* ]]
  ! grep -q 'curl' "$CALLS"
  ! grep -q '^mysql' "$CALLS"
  [ "$(marker attempts)" = 1 ]
}

@test "Q24 (c): started é lido antes das tabelas: limpa e reaplica do começo" {
  echo '{"schema":"started","state":"running","attempts":1,"manifest_hash":"hash-1"}' >"$MARKER_FILE"
  echo 1 >"$TABLES" # a tnf_queda criada no meio da tentativa
  db_init hash-2
  [ "$output" = ok ]
  grep -q 'DROP TABLE' "$CALLS"
  grep -q 'curl' "$CALLS"
  [ "$(marker schema)" = applied ]
  [ "$(marker state)" = done ]
}

@test "Q13: download que falha grava failed apontando a referência, sem tabelas" {
  export DOWNLOAD_FAIL=1
  db_init
  [[ "$output" == "failed não foi possível baixar o script do schema"*"db_schema_ref (v1.0.0)"* ]]
  [ "$(marker schema)" = failed ]
  [ "$(cat "$TABLES")" = 0 ]
}

@test "Q13: depois de corrigir a referência (hash novo), aplica sem recriar nada" {
  export DOWNLOAD_FAIL=1
  db_init hash-1
  export DOWNLOAD_FAIL=0
  db_init hash-2
  [ "$output" = ok ]
  [ "$(marker state)" = done ]
}

@test "banco com tabelas (snapshot): não baixa o script, mas configura o tnf_app" {
  echo 5 >"$TABLES"
  db_init
  [ "$output" = ok ]
  ! grep -q 'curl' "$CALLS"
  grep -q "ALTER USER 'tnf_app'" "$CALLS"
  [ "$(marker state)" = done ]
}

@test "banco vazio com db_schema_* em branco: failed pedindo para preenchê-las" {
  sed -i 's/^DB_SCHEMA_REF=.*/DB_SCHEMA_REF=/' "$W/stack.env"
  db_init
  [[ "$output" == "failed o banco está vazio e db_schema_* estão em branco; preencha-as em envs/dev/terraform.tfvars"* ]]
}

@test "sem DB_ENDPOINT ainda: aguarda" {
  sed -i 's/^DB_ENDPOINT=.*/DB_ENDPOINT=/' "$W/stack.env"
  db_init
  [ "$status" -eq 0 ]
  [[ "$output" == waiting* ]]
}
