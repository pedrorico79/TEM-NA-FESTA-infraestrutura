#!/usr/bin/env bash
# Snapshots do banco do ambiente (05, B2; 08, seção 5.5).
#
# Uso: scripts/snapshots.sh <comando> <env> [id]
#   choose <env> [id]  escolhe o snapshot do infra up: só em ambiente novo;
#                      sem id, o final mais recente; com id, um final ou manual
#                      do ambiente, disponível. Imprime o id (ou nada).
#   list <env>         lista os snapshots do ambiente (nome, tipo, data, tamanho, estado)
#   create <env>       tira um snapshot manual <prefixo>-manual-<AAAAMMDD-HHMMSS UTC>
#   prune <env>        mantém os 3 finais e os 3 manuais mais recentes do ambiente
# Os comandos choose e create leem o state (terraform state list) da raiz
# envs/<env>, que o infra já inicializou. Saída: 0 ok; 2 recusado (com o que
# fazer); 1 erro inesperado.
set -euo pipefail

INFRA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=scripts/lib/common.sh
source "$INFRA_ROOT/scripts/lib/common.sh"

usage() { sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

CMD="${1:-}" ENV_NAME="${2:-}" ARG="${3:-}"
case "$CMD" in -h | --help | "") usage; exit 0 ;; esac
case "$ENV_NAME" in
  dev | prod) ;;
  *) die "$EXIT_PRECONDITION" "informe o ambiente: dev ou prod (03, T1)." ;;
esac

REGION="$(env_region "$ENV_NAME")"
PREFIX="$(read_tfvar "$INFRA_ROOT/envs/$ENV_NAME/terraform.tfvars" project_name tem-na-festa)-$ENV_NAME"
TF_DIR="$(env_tf_dir "$ENV_NAME")"
RDS_ADDRESS="module.environment.module.database.aws_db_instance.this"

# env_snapshots: "<id> <tipo> <data> <GB> <estado>" dos snapshots do ambiente, do mais novo ao mais antigo.
env_snapshots() {
  aws rds describe-db-snapshots --snapshot-type manual --region "$REGION" --output json |
    jq -r --arg p "$PREFIX" '
      .DBSnapshots
      | map(select(.DBSnapshotIdentifier | startswith($p + "-final-") or startswith($p + "-manual-")))
      | sort_by(.SnapshotCreateTime // "") | reverse | .[]
      | [.DBSnapshotIdentifier,
         (if (.DBSnapshotIdentifier | startswith($p + "-final-")) then "final" else "manual" end),
         (.SnapshotCreateTime // "-"), ((.AllocatedStorage // 0) | tostring), .Status] | join(" ")'
}

env_is_up() {
  terraform -chdir="$TF_DIR" state list 2>/dev/null | grep -qx "$RDS_ADDRESS"
}

print_list() {
  local rows
  rows="$(env_snapshots)"
  if [[ -z "$rows" ]]; then
    echo "nenhum snapshot do ambiente $ENV_NAME em $REGION" >&2
    return 0
  fi
  {
    echo "NOME TIPO CRIADO_EM GB ESTADO"
    echo "$rows"
  } | column -t >&2
}

cmd_choose() {
  if env_is_up; then
    if [[ -n "$ARG" ]]; then
      die "$EXIT_PRECONDITION" "o ambiente $ENV_NAME já está no ar: --snapshot só vale num ambiente novo, porque o banco em uso nunca é trocado por um infra up (05, B2). Para restaurar, rode 'infra down $ENV_NAME' e 'infra up $ENV_NAME --snapshot $ARG'."
    fi
    return 0
  fi
  local rows
  rows="$(env_snapshots)"
  if [[ -n "$ARG" ]]; then
    if [[ "$ARG" != "$PREFIX-final-"* && "$ARG" != "$PREFIX-manual-"* ]]; then
      print_list
      die "$EXIT_PRECONDITION" "o snapshot '$ARG' não é do ambiente $ENV_NAME (o nome precisa começar com $PREFIX-final- ou $PREFIX-manual-). Os do ambiente estão listados acima."
    fi
    if ! grep -q "^$ARG [a-z]* [^ ]* [0-9]* available$" <<<"$rows"; then
      print_list
      die "$EXIT_PRECONDITION" "o snapshot '$ARG' não existe ou não está disponível em $REGION. Os do ambiente estão listados acima."
    fi
    echo "$ARG"
    return 0
  fi
  local latest
  latest="$(awk '$2 == "final" && $5 == "available" {print $1; exit}' <<<"$rows")"
  if [[ -n "$latest" ]]; then
    say_info "o banco será restaurado do snapshot final mais recente: $latest" >&2
    echo "$latest"
  else
    say_warn "nenhum snapshot final do ambiente $ENV_NAME: o banco nascerá vazio, e db_schema_repo_url, db_schema_ref e db_schema_path precisam estar preenchidas em envs/$ENV_NAME/terraform.tfvars (03, seção 3.8)." >&2
  fi
}

cmd_create() {
  env_is_up || die "$EXIT_PRECONDITION" "o ambiente $ENV_NAME não está no ar: não há banco para fotografar."
  local name
  name="$PREFIX-manual-$(date -u +%Y%m%d-%H%M%S)"
  aws rds create-db-snapshot --region "$REGION" --db-instance-identifier "$PREFIX-db" \
    --db-snapshot-identifier "$name" >/dev/null
  echo "aguardando o snapshot $name ficar disponível..." >&2
  aws rds wait db-snapshot-available --region "$REGION" --db-snapshot-identifier "$name"
  say_ok "snapshot manual criado: $name (não é restaurado sozinho; use 'infra up $ENV_NAME --snapshot $name' num ambiente novo)." >&2
  echo "$name"
}

cmd_prune() {
  local rows kind id
  rows="$(env_snapshots)"
  for kind in final manual; do
    while read -r id; do
      [[ -n "$id" ]] || continue
      aws rds delete-db-snapshot --region "$REGION" --db-snapshot-identifier "$id" >/dev/null
      say_info "snapshot $kind antigo apagado: $id" >&2
    done < <(awk -v k="$kind" '$2 == k {print $1}' <<<"$rows" | tail -n +4)
  done
}

case "$CMD" in
  choose) cmd_choose ;;
  list) print_list ;;
  create) cmd_create ;;
  prune) cmd_prune ;;
  *) die "$EXIT_PRECONDITION" "comando desconhecido: $CMD (use --help)" ;;
esac
