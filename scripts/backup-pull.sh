#!/usr/bin/env bash
# Cópia 4 da política de backup (docs/politica-de-backup.md): traz as cópias
# criptografadas do S3 para o computador do autor (fora da AWS, desconectada
# quando o computador está desligado) e confere o sha256 de cada conjunto.
# Uso: scripts/backup-pull.sh <env> [destino]   (destino: ~/tnf-backups)
# Pode ir no cron do WSL, por exemplo: 30 8 * * * <repo>/scripts/backup-pull.sh prod
set -euo pipefail

INFRA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=scripts/lib/common.sh
source "$INFRA_ROOT/scripts/lib/common.sh"

ENV_NAME="${1:-}"
case "$ENV_NAME" in dev | prod) ;; *) die "$EXIT_PRECONDITION" "uso: scripts/backup-pull.sh <dev|prod> [destino]" ;; esac
DEST="${2:-$HOME/tnf-backups}/$ENV_NAME"
BACKUP_REGION="${TNF_BACKUP_REGION:-us-west-2}"
account="$(aws sts get-caller-identity --query Account --output text)" ||
  die "$EXIT_PRECONDITION" "sem credenciais da AWS: atualize ~/.aws/credentials com as do laboratório."
BUCKET="tnf-backup-$account-$BACKUP_REGION"

mkdir -p "$DEST"
aws s3 sync "s3://$BUCKET/$ENV_NAME/" "$DEST/" --region "$BACKUP_REGION" --only-show-errors
erros=0
while IFS= read -r sums; do
  dir="$(dirname "$sums")"
  if (cd "$dir" && sha256sum --check --ignore-missing --quiet SHA256SUMS); then
    say_ok "${dir#"$DEST"/}: íntegro"
  else
    say_miss "${dir#"$DEST"/}: CORROMPIDO"
    erros=$((erros + 1))
  fi
done < <(find "$DEST" -name SHA256SUMS | sort)
[[ "$erros" -eq 0 ]] || die "$EXIT_UNEXPECTED" "$erros conjunto(s) não conferem com o SHA256SUMS"
say_ok "cópias em $DEST conferidas (0 erros)"
