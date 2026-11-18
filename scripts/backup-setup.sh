#!/usr/bin/env bash
# Preparação única da política de backup (docs/politica-de-backup.md), rodada
# pelo autor no WSL com as credenciais do laboratório. Idempotente.
#   1. bucket de backup tnf-backup-<conta>-us-west-2 (cópia 3, fora da região
#      do ambiente), criado pelo AWS CLI (a SCP do laboratório impede o
#      aws_s3_bucket do Terraform, 08 H20): versionamento, SSE-S3, bloqueio
#      de acesso público, só TLS e ciclo de vida (diário 35 dias, logs 180
#      dias, versões antigas 7 dias). Nunca é apagado pelo infra down.
#   2. par de chaves GPG do backup em ~/.tnf-backup/gnupg (pede a senha):
#      Curve25519 (cv25519 para cifrar), pequena o bastante para o SSM padrão.
#   3. chave pública em s3://<bucket>/chaves/ (os nós só cifram);
#      chave privada protegida pela senha em ~/.tnf-backup/tnf-backup-privada.asc
#      (600) e no SSM /tnf/backup/gpg_private_key (SecureString), para a
#      restauração nos nós. A senha da chave fica só com o autor.
# Uso: scripts/backup-setup.sh
set -euo pipefail

INFRA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=scripts/lib/common.sh
source "$INFRA_ROOT/scripts/lib/common.sh"

REGION_ENV="${TNF_REGION:-us-east-1}"
BACKUP_REGION="${TNF_BACKUP_REGION:-us-west-2}"
KEY_DIR="${TNF_BACKUP_KEY_DIR:-$HOME/.tnf-backup}"
UID_KEY="Tem Na Festa Backup <backup@temnafesta.com.br>"
export GNUPGHOME="$KEY_DIR/gnupg"

account="$(aws sts get-caller-identity --query Account --output text)" ||
  die "$EXIT_PRECONDITION" "sem credenciais da AWS: atualize ~/.aws/credentials com as do laboratório."
BUCKET="tnf-backup-$account-$BACKUP_REGION"

# --- 1. bucket ------------------------------------------------------------------------------
if aws s3api head-bucket --bucket "$BUCKET" --region "$BACKUP_REGION" 2>/dev/null; then
  say_ok "bucket $BUCKET já existe"
else
  aws s3api create-bucket --bucket "$BUCKET" --region "$BACKUP_REGION" \
    --create-bucket-configuration "LocationConstraint=$BACKUP_REGION" >/dev/null
  say_ok "bucket $BUCKET criado em $BACKUP_REGION"
fi
aws s3api put-bucket-versioning --bucket "$BUCKET" --region "$BACKUP_REGION" \
  --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket "$BUCKET" --region "$BACKUP_REGION" \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
aws s3api put-public-access-block --bucket "$BUCKET" --region "$BACKUP_REGION" \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-policy --bucket "$BUCKET" --region "$BACKUP_REGION" --policy "$(jq -cn --arg b "$BUCKET" '{
  Version: "2012-10-17",
  Statement: [{Sid: "DenyInsecureTransport", Effect: "Deny", Principal: "*", Action: "s3:*",
    Resource: ["arn:aws:s3:::\($b)", "arn:aws:s3:::\($b)/*"],
    Condition: {Bool: {"aws:SecureTransport": "false"}}}]}')"
rules='[]'
for env in dev prod; do
  rules="$(jq -c --arg e "$env" '. + [
    {ID: ($e + "-diario"),  Status: "Enabled", Filter: {Prefix: ($e + "/diario/")},  Expiration: {Days: 35}},
    {ID: ($e + "-logs"),    Status: "Enabled", Filter: {Prefix: ($e + "/logs/")},    Expiration: {Days: 180}}]' <<<"$rules")"
done
rules="$(jq -c '. + [{ID: "versoes-antigas", Status: "Enabled", Filter: {Prefix: ""},
  NoncurrentVersionExpiration: {NoncurrentDays: 7}}]' <<<"$rules")"
aws s3api put-bucket-lifecycle-configuration --bucket "$BUCKET" --region "$BACKUP_REGION" \
  --lifecycle-configuration "{\"Rules\":$rules}"
say_ok "bucket configurado: versionamento, SSE-S3, sem acesso público, só TLS, ciclo de vida"

# --- 2. chaves --------------------------------------------------------------------------------
mkdir -p "$GNUPGHOME"
chmod 700 "$KEY_DIR" "$GNUPGHOME"
if ! gpg --list-secret-keys "$UID_KEY" >/dev/null 2>&1; then
  say_info "gerando o par de chaves do backup; o GPG vai pedir a senha da chave privada (guarde-a no gerenciador de senhas)"
  gpg --quick-generate-key "$UID_KEY" future-default default 2y
fi
FPR="$(gpg --with-colons --list-secret-keys "$UID_KEY" | awk -F: '$1 == "fpr" { print $10; exit }')"
gpg --list-secret-keys --keyid-format LONG "$UID_KEY"

# --- 3. publicação das chaves -----------------------------------------------------------------
gpg --armor --export "$FPR" >"$KEY_DIR/tnf-backup-publica.asc"
gpg --armor --export-secret-keys "$FPR" >"$KEY_DIR/tnf-backup-privada.asc"
chmod 600 "$KEY_DIR/tnf-backup-privada.asc"
aws s3 cp "$KEY_DIR/tnf-backup-publica.asc" "s3://$BUCKET/chaves/tnf-backup-publica.asc" --region "$BACKUP_REGION" --only-show-errors
printf '%s\n' "$FPR" | aws s3 cp - "s3://$BUCKET/chaves/fingerprint.txt" --region "$BACKUP_REGION" --only-show-errors
aws ssm put-parameter --name /tnf/backup/gpg_private_key --type SecureString --overwrite \
  --value "file://$KEY_DIR/tnf-backup-privada.asc" --region "$REGION_ENV" >/dev/null
say_ok "chave pública em s3://$BUCKET/chaves/; privada em $KEY_DIR/tnf-backup-privada.asc e no SSM /tnf/backup/gpg_private_key"
say_info "fingerprint: $FPR"
