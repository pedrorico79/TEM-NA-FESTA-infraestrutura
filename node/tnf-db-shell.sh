#!/usr/bin/env bash
# tnf-db-shell (05, A7): abre o cliente MySQL no RDS do ambiente com o usuário
# administrador. A senha é lida do SSM pelo IMDSv2 do host e entregue ao
# cliente por um arquivo de opções temporário em /run, permissão 600, removido
# ao fim (05, A6). Instalado só nos nós app.
set -euo pipefail

# O arquivo de opções vai para /run, que só o root grava: reexecuta com sudo.
if [[ "$(id -u)" -ne 0 ]]; then
  exec sudo "$0" "$@"
fi

# shellcheck source=/dev/null
source /etc/tnf-node.env
S3="s3://$TNF_ARTIFACTS_BUCKET"

stack_env="$(aws s3 cp "$S3/stack.env" - --region "$TNF_REGION" 2>/dev/null)" || {
  echo "ERRO: não foi possível ler o stack.env do bucket de artefatos." >&2
  exit 2
}
endpoint="$(sed -n 's/^DB_ENDPOINT=//p' <<<"$stack_env")"
db_name="$(sed -n 's/^DB_NAME=//p' <<<"$stack_env")"
if [[ -z "$endpoint" ]]; then
  echo "ERRO: o stack.env ainda não tem DB_ENDPOINT. O banco do ambiente chega na etapa E4b." >&2
  exit 2
fi
# O usuário administrador é o db_master_username do ambiente, lido do próprio RDS.
admin="$(aws rds describe-db-instances --region "$TNF_REGION"   --query "DBInstances[?Endpoint.Address=='$endpoint'].MasterUsername | [0]" --output text)"

opts="$(mktemp -p /run tnf-db-shell.XXXXXX)"
trap 'rm -f "$opts"' EXIT
chmod 600 "$opts"
set +x
{
  printf '[client]\nuser=%s\nhost=%s\n' "${admin:-tnf_admin}" "$endpoint"
  printf 'password='
  aws ssm get-parameter --with-decryption --name "/tnf/$TNF_ENV/secrets/db_admin_password" \
    --query Parameter.Value --output text --region "$TNF_REGION"
} >"$opts"

mysql --defaults-extra-file="$opts" "${db_name:-tem_na_festa}" "$@"
