#!/usr/bin/env bash
# tnf-backup: backup diário do ambiente pela política 3-2-1 (docs/politica-de-backup.md).
# Executado pelo cron (/etc/cron.d/tnf-backup) todo dia às 03:00 de Brasília nos
# nós app; só age no app-1, que tem o cliente MySQL e acesso ao RDS.
#
# As três cópias: 1, produção (RDS e bucket bronze dos logs); 2, S3 em outra
# região (s3://<bucket>/<env>/diario/<carimbo>/, só .gpg e SHA256SUMS);
# 3, offline no computador do autor (scripts/backup-pull.sh).
#
# Cada execução monta o conjunto em /bckp/<carimbo>/, uma área de trânsito que
# é apagada depois do envio conferido:
#   db/<schema>.sql.gz        dump de cada schema (mysqldump | gzip)
#   app/config.tar.gz         stack.env, compose files, tnf-node.env e as
#                             imagens em execução (o que reconstrói a aplicação)
#   logs/logs.tar.gz          logs do bucket bronze (docker, com o acesso do
#                             Nginx; auth; systemd) dos dias completos desde o
#                             backup anterior (até 14 dias)
#   contagens.tsv             linhas por tabela no momento do dump (validação)
#   *.gpg                     cópia criptografada de cada arquivo (chave pública)
#   SHA256SUMS                sha256 de todos os arquivos acima
# Depois do envio, o script baixa de volta e confere o sha256 (prova de que a
# transferência não corrompeu nada). A senha do banco nunca vai na linha de
# comando: arquivo de opções em /run, permissão 600, apagado ao fim (05, A6).
#
# Uso: tnf-backup [--force] [--se-atrasado] [--manter-local]
#   --force: roda fora do app-1.
#   --se-atrasado: só faz o backup se o último conjunto no S3 tiver mais de
#     24 h (o laboratório raramente está no ar às 3 h; o cron chama assim a
#     cada hora para recuperar o diário perdido, e não faz nada no resto).
#   --manter-local: não apaga a área de trânsito no fim (para inspeção).
# Variáveis (opcionais): TNF_BACKUP_DIR (/bckp), TNF_BACKUP_BUCKET
#   (tnf-backup-<conta>-us-west-2), TNF_BACKUP_REGION (us-west-2),
#   TNF_BACKUP_MIN_FREE_MB (500), TNF_BACKUP_LOG_DAYS (14), TNF_BRONZE_BUCKET
#   e TNF_BRONZE_REGION (lidos do /etc/fluent-bit/fluent-bit.conf).
# Saída: 0 ok; 1 erro (mensagem no log); 2 recusado (pré-condição).
set -euo pipefail
umask 027

# /run e /bckp são do root: reexecuta com sudo (os testes apontam TNF_BACKUP_RUN_DIR para outro lugar).
if [[ "$(id -u)" -ne 0 && -z "${TNF_BACKUP_RUN_DIR:-}" ]]; then
  exec sudo "$0" "$@"
fi

# shellcheck source=/dev/null
source "${TNF_NODE_ENV:-/etc/tnf-node.env}"
FORCE=0 IF_LATE=0 KEEP=0
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    --se-atrasado) IF_LATE=1 ;;
    --manter-local) KEEP=1 ;;
    *) echo "opção desconhecida: $arg" >&2; exit 2 ;;
  esac
done

if [[ "$FORCE" -eq 0 && "$TNF_HOSTNAME" != *-app-1 ]]; then
  exit 0
fi

BACKUP_DIR="${TNF_BACKUP_DIR:-/bckp}"
BACKUP_REGION="${TNF_BACKUP_REGION:-us-west-2}"
MIN_FREE_MB="${TNF_BACKUP_MIN_FREE_MB:-500}"
GNUPGHOME="${TNF_BACKUP_GNUPGHOME:-/var/lib/tnf-backup/gnupg}"
RUN_DIR="${TNF_BACKUP_RUN_DIR:-/run}"
export GNUPGHOME
S3_ARTIFACTS="s3://$TNF_ARTIFACTS_BUCKET"

log() { printf '%s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$TNF_HOSTNAME" "$*"; }
fail() { log "FALHA: $*"; exit 1; }

# Uma execução por vez: o cron da hora seguinte não atropela uma lenta.
mkdir -p "$BACKUP_DIR"
exec 9>"$BACKUP_DIR/.lock"
flock -n 9 || { log "outra execução em andamento; nada a fazer"; exit 0; }

if [[ -z "${TNF_BACKUP_BUCKET:-}" ]]; then
  account="$(aws sts get-caller-identity --query Account --output text --region "$TNF_REGION")"
  TNF_BACKUP_BUCKET="tnf-backup-$account-$BACKUP_REGION"
fi
S3_BACKUP="s3://$TNF_BACKUP_BUCKET"

# Último conjunto no S3: decide o --se-atrasado e de que dia em diante entram os logs.
last="$({ aws s3 ls "$S3_BACKUP/$TNF_ENV/diario/" --region "$BACKUP_REGION" 2>/dev/null || true; } |
  awk '$1 == "PRE" { sub("/", "", $2); print $2 }' | sort | tail -n 1)"
if [[ "$IF_LATE" -eq 1 ]]; then
  if [[ -n "$last" ]]; then
    last_epoch=$(date -u -d "$(sed 's/_/ /; s/-\([0-9][0-9]\)$/:\1/' <<<"$last")" +%s)
    if (($(date -u +%s) - last_epoch < 24 * 3600)); then
      exit 0 # o diário está em dia
    fi
  fi
  log "último backup diário: ${last:-nenhum}; mais de 24 h, fazendo agora"
fi

STAMP="$(date -u +%Y-%m-%d_%H-%M)"
SET="$BACKUP_DIR/$STAMP"
START=$(date +%s)
log "início do backup $STAMP (ambiente $TNF_ENV, destino $S3_BACKUP)"

# --- 1. sanidade do disco (df -hT) ---------------------------------------------------
df -hT "$BACKUP_DIR" | sed 's/^/  /'
free_mb=$(df -Pm "$BACKUP_DIR" | awk 'NR == 2 { print $4 }')
if ((free_mb < MIN_FREE_MB)); then
  log "RECUSADO: só ${free_mb} MB livres em $BACKUP_DIR (mínimo ${MIN_FREE_MB} MB). Aumente o disco ou anexe um volume temporário."
  exit 2
fi
if [[ -e "$SET" ]]; then
  log "RECUSADO: já existe o conjunto $STAMP (duas execuções no mesmo minuto); rode de novo no minuto seguinte."
  exit 2
fi
mkdir -p "$SET/db" "$SET/app"
# A área de trânsito some no fim (com sucesso ou não); o arquivo de opções e a conferência também.
cleanup() {
  if [[ "$KEEP" -eq 0 ]]; then rm -rf "$SET"; fi
  rm -f "${OPTS:-}"
  rm -rf "${CHECK_DIR:-}"
}
trap cleanup EXIT

# --- 2. configuração do banco ----------------------------------------------------------
stack_env="$(aws s3 cp "$S3_ARTIFACTS/stack.env" - --region "$TNF_REGION" 2>/dev/null)" ||
  fail "não foi possível ler o stack.env do bucket de artefatos"
envval() { sed -n "s/^$1=//p" <<<"$stack_env" | tail -n 1; }
DB_ENDPOINT="$(envval DB_ENDPOINT)"
SCHEMAS=("$(envval DB_NAME)")
msg_db="$(envval MESSAGING_DB_NAME)"
[[ -n "$msg_db" ]] && SCHEMAS+=("$msg_db")
[[ -n "$DB_ENDPOINT" && -n "${SCHEMAS[0]}" ]] || fail "stack.env sem DB_ENDPOINT ou DB_NAME"

OPTS="$(mktemp -p "$RUN_DIR" tnf-backup.XXXXXX)"
chmod 600 "$OPTS"
if [[ -n "${TNF_BACKUP_DB_DEFAULTS:-}" ]]; then
  cat "$TNF_BACKUP_DB_DEFAULTS" >"$OPTS" # testes: arquivo de opções pronto
else
  admin="$(aws rds describe-db-instances --region "$TNF_REGION" \
    --query "DBInstances[?Endpoint.Address=='$DB_ENDPOINT'].MasterUsername | [0]" --output text)"
  set +x
  {
    printf '[client]\nuser=%s\nhost=%s\n' "${admin:-tnf_admin}" "$DB_ENDPOINT"
    printf 'password='
    aws ssm get-parameter --with-decryption --name "/tnf/$TNF_ENV/secrets/db_admin_password" \
      --query Parameter.Value --output text --region "$TNF_REGION"
  } >"$OPTS"
fi

# --- 3. dump de cada schema e contagem de linhas ----------------------------------------
dump_flags=(--single-transaction --quick --routines --triggers --no-tablespaces --hex-blob --default-character-set=utf8mb4)
# MySQL 8: sem GTID no dump (o RDS de destino tem os próprios); o mysqldump do MariaDB não tem a opção.
mysqldump --help 2>/dev/null | grep -q -- '--set-gtid-purged' && dump_flags+=(--set-gtid-purged=OFF)
: >"$SET/contagens.tsv"
for schema in "${SCHEMAS[@]}"; do
  t0=$(date +%s)
  mysqldump --defaults-extra-file="$OPTS" "${dump_flags[@]}" "$schema" | gzip -9 >"$SET/db/$schema.sql.gz" ||
    fail "mysqldump de $schema"
  gzip -t "$SET/db/$schema.sql.gz" || fail "gzip de $schema corrompido"
  # Contagem exata (COUNT(*)), tabela por tabela, para conferir a restauração.
  mysql --defaults-extra-file="$OPTS" -N -B -e \
    "SELECT table_name FROM information_schema.tables WHERE table_schema='$schema' AND table_type='BASE TABLE' ORDER BY table_name" |
    while read -r table; do
      n=$(mysql --defaults-extra-file="$OPTS" -N -B -e "SELECT COUNT(*) FROM \`$schema\`.\`$table\`")
      printf '%s\t%s\t%s\n' "$schema" "$table" "$n" >>"$SET/contagens.tsv"
    done
  log "dump $schema: $(du -h "$SET/db/$schema.sql.gz" | cut -f1) em $(($(date +%s) - t0)) s"
done

# --- 4. arquivos da aplicação -------------------------------------------------------------
stage="$SET/.config"
mkdir -p "$stage/stacks"
printf '%s\n' "$stack_env" >"$stage/stack.env"
aws s3 cp "$S3_ARTIFACTS/stacks/" "$stage/stacks/" --recursive --region "$TNF_REGION" --only-show-errors ||
  fail "download dos compose files"
cp "${TNF_NODE_ENV:-/etc/tnf-node.env}" "$stage/tnf-node.env"
# Imagens por digest em execução: o que estava no ar no momento do backup.
if command -v docker >/dev/null && docker info --format '{{.Swarm.ControlAvailable}}' 2>/dev/null | grep -q true; then
  docker service ls --format '{{.Name}} {{.Image}}' >"$stage/servicos.txt" || true
fi
tar -czf "$SET/app/config.tar.gz" -C "$stage" . || fail "tar da configuração"
rm -rf "$stage"
log "configuração: $(du -h "$SET/app/config.tar.gz" | cut -f1)"

# --- 4b. logs do bronze: os dias completos desde o backup anterior ---------------------------
FB_CONF="${TNF_FLUENT_BIT_CONF:-/etc/fluent-bit/fluent-bit.conf}"
BRONZE="${TNF_BRONZE_BUCKET:-$(awk '$1 == "bucket" { print $2; exit }' "$FB_CONF" 2>/dev/null || true)}"
BRONZE_REGION="${TNF_BRONZE_REGION:-$(awk '$1 == "region" { print $2; exit }' "$FB_CONF" 2>/dev/null || true)}"
BRONZE_REGION="${BRONZE_REGION:-$TNF_REGION}"
LOG_DAYS="${TNF_BACKUP_LOG_DAYS:-14}"
if [[ -z "$BRONZE" ]]; then
  log "AVISO: bucket bronze não encontrado em $FB_CONF; conjunto sem logs"
else
  # O conjunto anterior (do dia L) levou os logs até L-1: este leva de L até ontem.
  # Sem conjunto anterior, só ontem. No máximo LOG_DAYS dias.
  first="$(date -u -d "-$LOG_DAYS day" +%F)"
  if [[ -n "$last" ]]; then
    [[ "${last%%_*}" > "$first" ]] && first="${last%%_*}"
  else
    first="$(date -u -d '-1 day' +%F)"
  fi
  today="$(date -u +%F)"
  raw="$SET/.logs"
  mkdir -p "$raw"
  sources="$({ aws s3 ls "s3://$BRONZE/logs/env=$TNF_ENV/" --region "$BRONZE_REGION" 2>/dev/null || true; } |
    awk '$1 == "PRE" { sub("/", "", $2); print $2 }')"
  d="$first" days=()
  while [[ "$d" < "$today" ]]; do
    for src in $sources; do
      aws s3 cp "s3://$BRONZE/logs/env=$TNF_ENV/$src/year=${d:0:4}/month=${d:5:2}/day=${d:8:2}/" "$raw/$d/$src/" \
        --recursive --region "$BRONZE_REGION" --only-show-errors 2>/dev/null || true
    done
    [[ -d "$raw/$d" ]] && days+=("$d")
    d="$(date -u -d "$d + 1 day" +%F)"
  done
  n=$(find "$raw" -type f | wc -l)
  if ((n > 0)); then
    mkdir -p "$SET/logs"
    tar -czf "$SET/logs/logs.tar.gz" -C "$raw" . || fail "tar dos logs"
    log "logs: ${days[*]} ($n arquivos do bronze, $(du -h "$SET/logs/logs.tar.gz" | cut -f1) compactados)"
  else
    log "logs: nenhum arquivo no bronze de $first até ontem"
  fi
  rm -rf "$raw"
fi

# --- 5. cópia criptografada (gpg, chave pública do bucket de backup) ----------------------
mkdir -p "$GNUPGHOME"
chmod 700 "$GNUPGHOME"
pub="$GNUPGHOME/tnf-backup-publica.asc"
aws s3 cp "$S3_BACKUP/chaves/tnf-backup-publica.asc" "$pub" --region "$BACKUP_REGION" --only-show-errors ||
  fail "chave pública ausente em $S3_BACKUP/chaves/ (rode scripts/backup-setup.sh)"
gpg --batch --quiet --import "$pub" 2>/dev/null
FPR="$(gpg --batch --with-colons --show-keys "$pub" | awk -F: '$1 == "fpr" { print $10; exit }')"
[[ -n "$FPR" ]] || fail "chave pública inválida"
(
  cd "$SET"
  for f in db/*.sql.gz app/config.tar.gz contagens.tsv $(ls logs/logs.tar.gz 2>/dev/null); do
    gpg --batch --yes --trust-model always --recipient "$FPR" --output "$f.gpg" --encrypt "$f"
  done
) || fail "criptografia"

# --- 6. checksum de todos os arquivos ------------------------------------------------------
(cd "$SET" && find . -type f ! -name SHA256SUMS -printf '%P\n' | sort | xargs sha256sum >"$BACKUP_DIR/.SHA256SUMS.tmp")
mv "$BACKUP_DIR/.SHA256SUMS.tmp" "$SET/SHA256SUMS"
log "SHA256SUMS: $(wc -l <"$SET/SHA256SUMS") arquivos"

# --- 7. cópia 2: S3 em outra região --------------------------------------------
dest="$S3_BACKUP/$TNF_ENV/diario/$STAMP"
t0=$(date +%s)
(
  cd "$SET"
  for f in SHA256SUMS $(find . -name '*.gpg' -printf '%P\n' | sort); do
    # --checksum-algorithm: o S3 também confere o SHA-256 de cada parte no recebimento.
    aws s3 cp "$f" "$dest/$f" --region "$BACKUP_REGION" --only-show-errors --checksum-algorithm SHA256
  done
) || fail "envio ao S3"
log "enviado para $dest em $(($(date +%s) - t0)) s"

# --- 8. prova de integridade: baixa de volta e confere o sha256 ----------------------------
CHECK_DIR="$(mktemp -d)"
aws s3 cp "$dest/" "$CHECK_DIR/" --recursive --region "$BACKUP_REGION" --only-show-errors || fail "download de conferência"
check_out="$(cd "$CHECK_DIR" && sha256sum --check --ignore-missing SHA256SUMS 2>&1)" || {
  printf '%s\n' "$check_out" | sed 's/^/  /'
  fail "o conteúdo no S3 não confere com o SHA256SUMS"
}
printf '%s\n' "$check_out" | sed 's/^/  /'
ok_count=$(grep -c ': OK$' <<<"$check_out")
log "integridade conferida no destino: $ok_count arquivos OK, 0 erros"

log "fim do backup $STAMP: $(du -sh "$SET" | cut -f1) enviados e conferidos, $(($(date +%s) - START)) s no total"
if [[ "$KEEP" -eq 0 ]]; then
  log "área de trânsito $SET apagada (as cópias ficam no S3 e no computador do autor)"
fi
