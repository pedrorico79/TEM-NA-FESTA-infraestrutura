#!/usr/bin/env bash
# Inicialização do banco (04, seção 7, passo 6; 05, A4 e B5), chamada pelo
# converge.sh no líder. Ordem:
#   1. lê status/db-init.json ANTES das tabelas: "done" não faz nada;
#      "started" (tentativa interrompida) limpa o schema e reaplica;
#      "failed" só tenta de novo se o hash do manifesto mudou;
#   2. com tabelas (snapshot ou já aplicado), não roda o script;
#   3. sem tabelas: baixa o script da tag fixada (3 tentativas), grava
#      "started", aplica; se falhar, remove tudo o que foi criado e grava
#      "failed" (sem repetir a cada minuto);
#   4. só com o schema completo: usuário tnf_app com a senha do ciclo,
#      revoga e concede SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, INDEX e
#      REFERENCES em <db>.* (sem DROP nem GRANT OPTION) e grava "done".
# A senha nunca vai na linha de comando: arquivo de opções em /run, 600,
# apagado ao fim (05, A6).
#
# Uso: db-init.sh <stack.env> <hash do manifesto>
# Saída (stdout, uma linha): "ok", "waiting <mensagem>" ou "failed <mensagem>".
set -euo pipefail

# shellcheck source=/dev/null
source "${TNF_NODE_ENV:-/etc/tnf-node.env}"
STACK_ENV="${1:?stack.env}"
MANIFEST_HASH="${2:?hash do manifesto}"
S3="s3://$TNF_ARTIFACTS_BUCKET"
STATUS_KEY="status/db-init.json"
APP_USER="tnf_app"
APP_PRIVS="SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, INDEX, REFERENCES"
CONNECT_WAIT=600 # até 10 min esperando o RDS aceitar conexão (04, seção 10)
LOG="${TNF_DB_INIT_LOG:-/var/log/tnf-db-init.log}"

envval() { sed -n "s/^$1=//p" "$STACK_ENV" | tail -n 1; }
log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$LOG"; }

DB_ENDPOINT="$(envval DB_ENDPOINT)"
DB_NAME="$(envval DB_NAME)"
REPO_URL="$(envval DB_SCHEMA_REPO_URL)"
REF="$(envval DB_SCHEMA_REF)"
SCRIPT_PATH="$(envval DB_SCHEMA_PATH)"

OPTS=""
# Sem "&&" solto: no trap de saída, um teste falso viraria o código de saída.
cleanup() {
  if [[ -n "$OPTS" ]]; then rm -f "$OPTS"; fi
}
trap cleanup EXIT

# --- marcador no bucket de artefatos ----------------------------------------------

read_marker() {
  MARKER="$(aws s3 cp "$S3/$STATUS_KEY" - --region "$TNF_REGION" 2>/dev/null || echo '{}')"
  M_STATE="$(jq -r '.state // ""' <<<"$MARKER")"
  M_SCHEMA="$(jq -r '.schema // ""' <<<"$MARKER")"
  M_HASH="$(jq -r '.manifest_hash // ""' <<<"$MARKER")"
  M_ATTEMPTS="$(jq -r '.attempts // 0' <<<"$MARKER")"
  M_ERROR="$(jq -r '.error // ""' <<<"$MARKER")"
}

# write_marker <schema> <state> <erro>
write_marker() {
  jq -n --arg schema "$1" --arg state "$2" --arg error "$3" --arg hash "$MANIFEST_HASH" \
    --argjson attempts "$M_ATTEMPTS" --arg time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{schema: $schema, state: $state, attempts: $attempts, manifest_hash: $hash, error: $error, time: $time}' |
    aws s3 cp - "$S3/$STATUS_KEY" --region "$TNF_REGION" --only-show-errors
  M_SCHEMA="$1" M_STATE="$2"
}

# --- conexão -----------------------------------------------------------------------

make_opts() {
  local admin
  admin="$(aws rds describe-db-instances --region "$TNF_REGION" \
    --query "DBInstances[?Endpoint.Address=='$DB_ENDPOINT'].MasterUsername | [0]" --output text)"
  OPTS="$(mktemp -p "${TNF_RUN_DIR:-/run}" tnf-db-init.XXXXXX)"
  chmod 600 "$OPTS"
  set +x
  {
    printf '[client]\nuser=%s\nhost=%s\npassword=' "$admin" "$DB_ENDPOINT"
    aws ssm get-parameter --with-decryption --name "/tnf/$TNF_ENV/secrets/db_admin_password" \
      --query Parameter.Value --output text --region "$TNF_REGION"
  } >"$OPTS"
}

sql() { mysql --defaults-extra-file="$OPTS" --batch --skip-column-names "$@"; }

wait_connection() {
  local waited=0
  until sql -e 'SELECT 1' >/dev/null 2>&1; do
    if ((waited >= CONNECT_WAIT)); then return 1; fi
    sleep 15
    waited=$((waited + 15))
  done
}

table_count() {
  sql -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = '$DB_NAME'"
}

# clear_schema: remove todos os objetos do schema (tabelas, visões, rotinas,
# gatilhos e eventos). Só é chamada quando o schema estava vazio no início da
# tentativa (05, B5).
clear_schema() {
  local stmts
  stmts="$(sql -e "
    SELECT CONCAT('DROP TRIGGER IF EXISTS \`', trigger_name, '\`;') FROM information_schema.triggers WHERE trigger_schema = '$DB_NAME'
    UNION ALL SELECT CONCAT('DROP EVENT IF EXISTS \`', event_name, '\`;') FROM information_schema.events WHERE event_schema = '$DB_NAME'
    UNION ALL SELECT CONCAT('DROP ', routine_type, ' IF EXISTS \`', routine_name, '\`;') FROM information_schema.routines WHERE routine_schema = '$DB_NAME'
    UNION ALL SELECT CONCAT('DROP VIEW IF EXISTS \`', table_name, '\`;') FROM information_schema.views WHERE table_schema = '$DB_NAME'
    UNION ALL SELECT CONCAT('DROP TABLE IF EXISTS \`', table_name, '\`;') FROM information_schema.tables WHERE table_schema = '$DB_NAME' AND table_type = 'BASE TABLE'")"
  { echo "SET FOREIGN_KEY_CHECKS=0;"; echo "$stmts"; echo "SET FOREIGN_KEY_CHECKS=1;"; } | sql "$DB_NAME"
  log "schema $DB_NAME limpo"
}

# raw_url: URL "raw" do arquivo no GitHub a partir do repositório, da tag e do caminho.
raw_url() {
  local repo="${REPO_URL%.git}"
  repo="${repo#https://github.com/}"
  printf 'https://raw.githubusercontent.com/%s/%s/%s' "$repo" "$REF" "$SCRIPT_PATH"
}

apply_schema() {
  local script err n
  script="$(mktemp)"
  err="$(mktemp)"
  M_ATTEMPTS=$((M_ATTEMPTS + 1))
  for n in 1 2 3; do
    if curl -fsSL --max-time 60 "$(raw_url)" -o "$script"; then break; fi
    if ((n == 3)); then
      write_marker failed failed "não foi possível baixar o script do schema de $(raw_url) (referência $REF) depois de 3 tentativas"
      rm -f "$script" "$err"
      echo "failed não foi possível baixar o script do schema ($(raw_url)). Confira db_schema_repo_url, db_schema_ref ($REF) e db_schema_path em envs/$TNF_ENV/terraform.tfvars e rode 'infra up $TNF_ENV'; o ambiente não precisa ser recriado."
      return 1
    fi
    sleep $((n * 10))
  done

  write_marker started running ""
  log "aplicando o script do schema ($REF)"
  if ! sql "$DB_NAME" <"$script" 2>"$err"; then
    local tail_err
    tail_err="$(tail -n 5 "$err" | tr '\n' ' ')"
    clear_schema
    write_marker failed failed "$tail_err"
    rm -f "$script" "$err"
    echo "failed o script do schema ($REF) falhou: $tail_err O schema foi limpo. Publique uma versão corrigida, aponte db_schema_ref para a tag nova em envs/$TNF_ENV/terraform.tfvars e rode 'infra up $TNF_ENV'; o ambiente não precisa ser recriado."
    return 1
  fi
  rm -f "$script" "$err"
  write_marker applied running ""
}

configure_app_user() {
  local pw
  set +x
  pw="$(aws ssm get-parameter --with-decryption --name "/tnf/$TNF_ENV/secrets/db_password" \
    --query Parameter.Value --output text --region "$TNF_REGION")"
  # A senha vai pela entrada padrão do cliente, nunca na linha de comando.
  sql <<SQL
CREATE USER IF NOT EXISTS '$APP_USER'@'%' IDENTIFIED BY '$pw';
ALTER USER '$APP_USER'@'%' IDENTIFIED BY '$pw';
REVOKE ALL PRIVILEGES, GRANT OPTION FROM '$APP_USER'@'%';
GRANT $APP_PRIVS ON \`$DB_NAME\`.* TO '$APP_USER'@'%';
SQL
  pw=""
  log "usuário $APP_USER configurado"
}

main() {
  read_marker
  if [[ "$M_STATE" == "done" ]]; then
    echo ok
    return 0
  fi
  if [[ "$M_SCHEMA" == failed && "$M_HASH" == "$MANIFEST_HASH" ]]; then
    echo "failed $M_ERROR (a tentativa só se repete depois de uma mudança aplicada por 'infra up $TNF_ENV')"
    return 0
  fi
  if [[ -z "$DB_ENDPOINT" ]]; then
    echo "waiting o stack.env ainda não tem DB_ENDPOINT"
    return 0
  fi
  make_opts
  if ! wait_connection; then
    echo "failed o RDS ($DB_ENDPOINT) não aceitou conexão em $((CONNECT_WAIT / 60)) minutos, ou o cliente MySQL não está no nó."
    return 0
  fi

  if [[ "$M_SCHEMA" == started ]]; then
    log "marcador started: a tentativa anterior foi interrompida; limpando o schema"
    clear_schema
  elif (($(table_count) > 0)); then
    log "o schema já tem tabelas (snapshot ou aplicado): o script não roda"
    M_SCHEMA="${M_SCHEMA:-snapshot}"
  fi

  if [[ "$M_SCHEMA" != applied && "$M_SCHEMA" != snapshot ]] && (($(table_count) == 0)); then
    if [[ -z "$REPO_URL" || -z "$REF" || -z "$SCRIPT_PATH" ]]; then
      echo "failed o banco está vazio e db_schema_* estão em branco; preencha-as em envs/$TNF_ENV/terraform.tfvars e rode 'infra up $TNF_ENV'."
      return 0
    fi
    apply_schema || return 0
  fi

  configure_app_user
  write_marker "${M_SCHEMA:-applied}" "done" ""
  echo ok
}

main
