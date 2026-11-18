#!/usr/bin/env bash
# tnf-backup-restore: restaura um conjunto do tnf-backup e mede o tempo de
# cada fase (docs/politica-de-backup.md, RTO). Instalado nos nós app.
#
# Uso: tnf-backup-restore [--carimbo <AAAA-MM-DD_HH-MM>]
#                         [--destino teste|producao] [--manter]
#   Baixa a cópia criptografada do S3 (cópia 2), confere o SHA256SUMS e
#   descriptografa com a chave privada.
#   --carimbo: o conjunto; sem ele, o mais recente.
#   --destino teste (padrão): restaura em schemas novos restore_<schema>, sem
#     tocar no banco do ambiente, e apaga esses schemas no fim (--manter não apaga).
#     producao: grava por cima dos schemas do ambiente (pede confirmação; pare o
#     backend antes: docker service scale tnf-app_backend=0).
# A chave privada vem do SSM (/tnf/backup/gpg_private_key) ou de
# TNF_BACKUP_PRIVATE_KEY_FILE; a senha da chave é pedida no terminal ou lida de
# TNF_BACKUP_PASSPHRASE_FILE. Ao fim, imprime o relatório (tempos por fase e
# contagem de linhas restauradas x registradas no backup) e o grava em
# /bckp/restauracoes/. Saída: 0 ok, 1 erro, 2 recusado.
set -euo pipefail
umask 077

# /run e /bckp são do root: reexecuta com sudo (os testes apontam TNF_BACKUP_RUN_DIR para outro lugar).
if [[ "$(id -u)" -ne 0 && -z "${TNF_BACKUP_RUN_DIR:-}" ]]; then
  exec sudo "$0" "$@"
fi

# shellcheck source=/dev/null
source "${TNF_NODE_ENV:-/etc/tnf-node.env}"
ORIGEM=s3 CARIMBO="" DESTINO=teste MANTER=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --carimbo) CARIMBO="$2"; shift 2 ;;
    --destino) DESTINO="$2"; shift 2 ;;
    --manter) MANTER=1; shift ;;
    -h | --help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "opção desconhecida: $1" >&2; exit 2 ;;
  esac
done
[[ "$DESTINO" == teste || "$DESTINO" == producao ]] || { echo "--destino teste ou producao" >&2; exit 2; }

BACKUP_DIR="${TNF_BACKUP_DIR:-/bckp}"
BACKUP_REGION="${TNF_BACKUP_REGION:-us-west-2}"
RUN_DIR="${TNF_BACKUP_RUN_DIR:-/run}"
S3_ARTIFACTS="s3://$TNF_ARTIFACTS_BUCKET"
if [[ -z "${TNF_BACKUP_BUCKET:-}" ]]; then
  account="$(aws sts get-caller-identity --query Account --output text --region "$TNF_REGION")"
  TNF_BACKUP_BUCKET="tnf-backup-$account-$BACKUP_REGION"
fi
S3_BACKUP="s3://$TNF_BACKUP_BUCKET"

WORK="$(mktemp -d)"
OPTS="$(mktemp -p "$RUN_DIR" tnf-restore.XXXXXX)"
export GNUPGHOME="$WORK/gnupg"
mkdir -p "$GNUPGHOME"
trap 'rm -rf "$WORK"; rm -f "$OPTS"' EXIT

now() { date +%s.%N; }
secs() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.1f", b - a }'; }
declare -a FASES=()
fase() { FASES+=("$(printf '%-34s %8s s' "$1" "$(secs "$2" "$(now)")")"); }
say() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*"; }

T_INICIO=$(now)

# --- 1. obter o conjunto ------------------------------------------------------------------
t=$(now)
if [[ "$ORIGEM" == s3 ]]; then
  if [[ -z "$CARIMBO" ]]; then
    CARIMBO="$({ aws s3 ls "$S3_BACKUP/$TNF_ENV/diario/" --region "$BACKUP_REGION" 2>/dev/null || true; } | awk '$1 == "PRE" { sub("/", "", $2); print $2 }' | sort | tail -n 1)"
    [[ -n "$CARIMBO" ]] || { echo "nenhum backup em $S3_BACKUP/$TNF_ENV/diario/" >&2; exit 2; }
  fi
  SET="$WORK/set"
  say "baixando $S3_BACKUP/$TNF_ENV/diario/$CARIMBO/"
  aws s3 cp "$S3_BACKUP/$TNF_ENV/diario/$CARIMBO/" "$SET/" --recursive --region "$BACKUP_REGION" --only-show-errors
  fase "download do S3 ($(du -sh "$SET" | cut -f1))" "$t"
fi

# --- 2. integridade ---------------------------------------------------------------------------
t=$(now)
CHECK="$(cd "$SET" && sha256sum --check --ignore-missing SHA256SUMS 2>&1)" || {
  printf '%s\n' "$CHECK"
  echo "ERRO: o conjunto $CARIMBO não confere com o SHA256SUMS; não restaurado." >&2
  exit 1
}
printf '%s\n' "$CHECK" | sed 's/^/  /'
fase "sha256sum --check ($(grep -c ': OK$' <<<"$CHECK") OK)" "$t"

# --- 3. descriptografia (só da origem s3) ---------------------------------------------------
if [[ "$ORIGEM" == s3 ]]; then
  t=$(now)
  key="$WORK/privada.asc"
  if [[ -n "${TNF_BACKUP_PRIVATE_KEY_FILE:-}" ]]; then
    cp "$TNF_BACKUP_PRIVATE_KEY_FILE" "$key"
  else
    aws ssm get-parameter --with-decryption --name /tnf/backup/gpg_private_key \
      --query Parameter.Value --output text --region "$TNF_REGION" >"$key"
  fi
  pass="$WORK/senha"
  if [[ -n "${TNF_BACKUP_PASSPHRASE_FILE:-}" ]]; then
    cp "$TNF_BACKUP_PASSPHRASE_FILE" "$pass"
  else
    read -r -s -p "Senha da chave de backup: " p </dev/tty; echo >/dev/tty
    printf '%s' "$p" >"$pass"; unset p
  fi
  gpg --batch --quiet --pinentry-mode loopback --passphrase-file "$pass" --import "$key" 2>/dev/null
  (
    cd "$SET"
    for f in $(find . -name '*.gpg' -printf '%P\n' | sort); do
      gpg --batch --quiet --pinentry-mode loopback --passphrase-file "$pass" --output "${f%.gpg}" --decrypt "$f"
    done
  ) || { echo "ERRO: descriptografia falhou (senha errada ou chave diferente)." >&2; exit 1; }
  # Os arquivos decifrados também têm de bater com o hash registrado na origem.
  (cd "$SET" && sha256sum --check --ignore-missing --quiet SHA256SUMS) || { echo "ERRO: decifrado difere do original" >&2; exit 1; }
  fase "gpg --decrypt + sha256 do original" "$t"
fi

# --- 4. banco ---------------------------------------------------------------------------------
stack_env="$(aws s3 cp "$S3_ARTIFACTS/stack.env" - --region "$TNF_REGION" 2>/dev/null)"
DB_ENDPOINT="$(sed -n 's/^DB_ENDPOINT=//p' <<<"$stack_env" | tail -n 1)"
chmod 600 "$OPTS"
if [[ -n "${TNF_BACKUP_DB_DEFAULTS:-}" ]]; then
  cat "$TNF_BACKUP_DB_DEFAULTS" >"$OPTS"
else
  admin="$(aws rds describe-db-instances --region "$TNF_REGION" \
    --query "DBInstances[?Endpoint.Address=='$DB_ENDPOINT'].MasterUsername | [0]" --output text)"
  {
    printf '[client]\nuser=%s\nhost=%s\npassword=' "${admin:-tnf_admin}" "$DB_ENDPOINT"
    aws ssm get-parameter --with-decryption --name "/tnf/$TNF_ENV/secrets/db_admin_password" \
      --query Parameter.Value --output text --region "$TNF_REGION"
  } >"$OPTS"
fi
sql() { mysql --defaults-extra-file="$OPTS" -N -B "$@"; }

if [[ "$DESTINO" == producao ]]; then
  read -r -p "Gravar o backup $CARIMBO POR CIMA do banco de $TNF_ENV? Digite o nome do ambiente: " r </dev/tty
  [[ "$r" == "$TNF_ENV" ]] || { echo "cancelado" >&2; exit 2; }
fi

declare -A ALVO=()
t=$(now)
for dump in "$SET"/db/*.sql.gz; do
  schema="$(basename "$dump" .sql.gz)"
  if [[ "$DESTINO" == teste ]]; then
    alvo="restore_$schema"
    sql -e "DROP DATABASE IF EXISTS \`$alvo\`; CREATE DATABASE \`$alvo\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"
  else
    alvo="$schema"
  fi
  ALVO[$schema]="$alvo"
  t1=$(now)
  gunzip -c "$dump" | sql "$alvo"
  fase "restauração $schema" "$t1"
done
fase "restauração do banco (total)" "$t"

# --- 5. validação: linhas restauradas x registradas no backup -------------------------------
t=$(now)
ERROS=0
RELATORIO_TAB="$(printf '%-28s %-26s %8s %8s %s\n' SCHEMA TABELA BACKUP RESTAUR. OK)"
while IFS=$'\t' read -r schema table n; do
  got=$(sql -e "SELECT COUNT(*) FROM \`${ALVO[$schema]}\`.\`$table\`" 2>/dev/null || echo "-")
  ok=sim
  [[ "$got" == "$n" ]] || { ok=NAO; ERROS=$((ERROS + 1)); }
  RELATORIO_TAB+=$'\n'"$(printf '%-28s %-26s %8s %8s %s' "$schema" "$table" "$n" "$got" "$ok")"
done <"$SET/contagens.tsv"
fase "validação das contagens" "$t"

# Arquivos da aplicação: o tar tem de abrir sem erro.
t=$(now)
mkdir -p "$WORK/config"
tar -xzf "$SET/app/config.tar.gz" -C "$WORK/config"
fase "tar -xzf config ($(find "$WORK/config" -type f | wc -l) arquivos)" "$t"
if [[ -f "$SET/logs/logs.tar.gz" ]]; then
  t=$(now)
  mkdir -p "$WORK/logs"
  tar -xzf "$SET/logs/logs.tar.gz" -C "$WORK/logs"
  fase "tar -xzf logs ($(find "$WORK/logs" -type f | wc -l) arquivos)" "$t"
fi

if [[ "$DESTINO" == teste && "$MANTER" -eq 0 ]]; then
  for alvo in "${ALVO[@]}"; do sql -e "DROP DATABASE \`$alvo\`"; done
fi

TOTAL="$(secs "$T_INICIO" "$(now)")"
idade=$(($(date -u +%s) - $(date -u -d "$(sed 's/_/ /; s/-\([0-9][0-9]\)$/:\1/' <<<"$CARIMBO")" +%s)))
mkdir -p "$BACKUP_DIR/restauracoes"
REL="$BACKUP_DIR/restauracoes/$(date -u +%Y-%m-%d_%H-%M-%S).txt"
{
  echo "Restauração do backup $CARIMBO ($TNF_ENV), origem $ORIGEM, destino $DESTINO"
  echo "Executada em $(date -u +%Y-%m-%dT%H:%M:%SZ) no $TNF_HOSTNAME"
  echo
  echo "Tempos por fase:"
  printf '  %s\n' "${FASES[@]}"
  printf '  %-34s %8s s\n' "TOTAL (tempo de restauração)" "$TOTAL"
  echo
  echo "Idade do backup no momento da restauração: $((idade / 60)) min (perda máxima se fosse um desastre agora)"
  echo
  echo "$RELATORIO_TAB"
  echo
  if [[ "$ERROS" -eq 0 ]]; then echo "RESULTADO: 0 erros"; else echo "RESULTADO: $ERROS tabela(s) com contagem diferente"; fi
} | tee "$REL"
echo "relatório gravado em $REL"
[[ "$ERROS" -eq 0 ]]
