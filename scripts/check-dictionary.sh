#!/usr/bin/env bash
# Confere o dicionário de dados (10, seção 10; D12) com as fontes:
#   - o script do banco na tag db_schema_ref (tabelas tem_na_festa.*);
#   - as colunas das tabelas do Glue em analytics/tabelas.json (tnf_bronze.*);
#   - o arquivo bruto da coleta dos produtos (tendencias_produtos.bruto), que
#     precisa descrever data_coleta e todos os campos do resumo do Glue, com
#     papel, tipo, domínio e exemplo preenchidos (10, DA8).
# Recusa tabela ou coluna faltando, sobrando ou com tipo diferente.
#
# Uso: scripts/check-dictionary.sh [--dict <md>] [--sql <arquivo>] [--tables <json>]
#   Sem --sql, baixa o script de db_schema_repo_url/db_schema_ref/db_schema_path
#   de envs/dev/terraform.tfvars.
# Saída: 0 tudo certo; 1 erro inesperado; 2 o dicionário diverge (cada
# problema listado com o que fazer).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DICT="$ROOT/docs/dicionario-de-dados.md"
TABLES="$ROOT/analytics/tabelas.json"
SQL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dict) DICT="${2:?}"; shift 2 ;;
    --sql) SQL="${2:?}"; shift 2 ;;
    --tables) TABLES="${2:?}"; shift 2 ;;
    -h | --help) sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "ERRO: opção desconhecida: $1" >&2; exit 2 ;;
  esac
done

for f in "$DICT" "$TABLES"; do
  [[ -f "$f" ]] || { echo "ERRO: arquivo não encontrado: $f" >&2; exit 2; }
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [[ -z "$SQL" ]]; then
  tfvars="$ROOT/envs/dev/terraform.tfvars"
  val() { sed -n -E "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"([^\"]*)\".*/\1/p" "$tfvars" | tail -n 1; }
  repo="$(val db_schema_repo_url)" ref="$(val db_schema_ref)" path="$(val db_schema_path)"
  repo="${repo%.git}"
  SQL="$WORK/schema.sql"
  curl -fsSL --max-time 60 "https://raw.githubusercontent.com/${repo#https://github.com/}/$ref/$path" -o "$SQL" ||
    { echo "ERRO: não foi possível baixar o script do banco ($repo, $ref, $path). Use --sql <arquivo>." >&2; exit 2; }
fi

# --- 1. dicionário: tabela, campo, papel, tipo, tamanho, obrigatório, domínio, exemplo ---
awk -F'|' '
  function limpa(s) { gsub(/`/, "", s); gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
  /^#/ {
    tabela = ""; cab = 0
    if (match($0, /^### `[^`]+`/)) { tabela = substr($0, RSTART + 5, RLENGTH - 6) }
    next
  }
  tabela == "" { next }
  /^\|/ {
    if (!cab) {
      for (i = 2; i < NF; i++) col[limpa($i)] = i
      cab = 1; next
    }
    if ($0 ~ /^\|[-| :]+$/) next
    campo = limpa($(col["Campo"]))
    papel = ("Papel" in col) ? limpa($(col["Papel"])) : ""
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", tabela, campo, papel, limpa($(col["Tipo"])), \
      limpa($(col["Tamanho"])), limpa($(col["Obrigatório"])), limpa($(col["Domínio e regra de validação"])), limpa($(col["Exemplo real"]))
    next
  }
  { cab = 0; delete col }
' "$DICT" >"$WORK/dict.tsv"

# --- 2. script do banco: tabela, campo, tipo ------------------------------------------------
awk '
  toupper($1 " " $2) == "CREATE TABLE" { t = $3; sub(/\(.*/, "", t); tabela = "tem_na_festa." t; next }
  tabela != "" && /^[ \t]*\)/ { tabela = ""; next }
  tabela != "" && NF >= 2 {
    c = $1
    if (toupper(c) ~ /^(FOREIGN|PRIMARY|UNIQUE|KEY|CONSTRAINT|INDEX|CHECK)$/) next
    if (c ~ /^--/) next
    tipo = toupper($2); sub(/,$/, "", tipo)
    printf "%s\t%s\t%s\n", tabela, c, tipo
  }
' "$SQL" >"$WORK/sql.tsv"

# --- 3. Glue: tabela, campo, tipo ---------------------------------------------------------
jq -r 'to_entries[] | .key as $t | .value | to_entries[] | ["tnf_bronze." + $t, .key, .value] | @tsv' \
  "$TABLES" >"$WORK/glue.tsv"

errors=()
err() { errors+=("$1"); }

# compara <fonte.tsv> <prefixo> <nome da fonte>
compara() {
  local fonte="$1" prefixo="$2" nome="$3" tabela campo tipo dtipo
  while IFS=$'\t' read -r tabela campo tipo; do
    dtipo="$(awk -F'\t' -v t="$tabela" -v c="$campo" '$1 == t && $2 == c { print $4; exit }' "$WORK/dict.tsv")"
    if ! awk -F'\t' -v t="$tabela" '$1 == t { f = 1 } END { exit !f }' "$WORK/dict.tsv"; then
      err "a tabela $tabela ($nome) não está no dicionário. Acrescente a seção ### \`$tabela\` com todas as colunas."
    elif ! awk -F'\t' -v t="$tabela" -v c="$campo" '$1 == t && $2 == c { f = 1 } END { exit !f }' "$WORK/dict.tsv"; then
      err "falta a coluna $campo ($tipo) da tabela $tabela ($nome) no dicionário."
    elif [[ "${dtipo^^}" != "${tipo^^}" ]]; then
      err "$tabela.$campo tem o tipo \"$dtipo\" no dicionário, mas \"$tipo\" em $nome. Corrija o dicionário."
    fi
  done <"$fonte"
  while IFS=$'\t' read -r tabela campo _; do
    [[ "$tabela" == "$prefixo".* ]] || continue
    if ! awk -F'\t' -v t="$tabela" -v c="$campo" '$1 == t && $2 == c { f = 1 } END { exit !f }' "$fonte"; then
      err "o dicionário descreve $tabela.$campo, que não existe na fonte ($nome). Remova a linha ou corrija o nome."
    fi
  done <"$WORK/dict.tsv"
}

compara "$WORK/sql.tsv" tem_na_festa "o script do banco"
compara "$WORK/glue.tsv" tnf_bronze "analytics/tabelas.json"

# --- 4. o bruto da coleta dos produtos (10, seção 5; DA8) --------------------------------------
# O bruto não é catalogado no Glue, mas é o arquivo entregue à disciplina: ele
# precisa descrever data_coleta e todos os campos do resumo, com papel, tipo,
# domínio e exemplo preenchidos.
BRUTO=tendencias_produtos.bruto
nomes=(campo papel tipo tamanho obrigatório domínio exemplo)
campos_bruto="$({ echo data_coleta; awk -F'\t' '$1 == "tnf_bronze.tendencias_produtos_resumo" { print $2 }' "$WORK/glue.tsv"; } | sort -u)"
if ! awk -F'\t' -v t="$BRUTO" '$1 == t { f = 1 } END { exit !f }' "$WORK/dict.tsv"; then
  err "a tabela $BRUTO não está no dicionário. Acrescente a seção ### \`$BRUTO\` com os campos do arquivo bruto."
else
  while read -r campo; do
    linha="$(awk -F'\t' -v t="$BRUTO" -v c="$campo" '$1 == t && $2 == c { print; exit }' "$WORK/dict.tsv")"
    if [[ -z "$linha" ]]; then
      err "falta o campo $campo em $BRUTO (o resumo do Glue o tem)."
      continue
    fi
    # awk, e não read -a: o tab é espaço para o read, que juntaria campos vazios.
    for i in 1 2 5 6; do
      [[ -n "$(awk -F'\t' -v n="$((i + 2))" '{ print $n }' <<<"$linha")" ]] ||
        err "$BRUTO.$campo: ${nomes[$i]} em branco no dicionário."
    done
  done <<<"$campos_bruto"
fi

if [[ ${#errors[@]} -gt 0 ]]; then
  echo "Dicionário de dados com problemas (${#errors[@]}):" >&2
  printf '  - %s\n' "${errors[@]}" >&2
  exit 2
fi
echo "Dicionário OK: $(cut -f1 "$WORK/sql.tsv" | sort -u | wc -l) tabelas do banco, $(cut -f1 "$WORK/glue.tsv" | sort -u | wc -l) do Glue e os $(wc -l <<<"$campos_bruto") campos do bruto da coleta conferidos."
