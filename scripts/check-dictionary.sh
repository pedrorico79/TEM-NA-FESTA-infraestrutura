#!/usr/bin/env bash
# Confere o dicionário de dados (10, seção 10; D12) com as fontes:
#   - o script do banco na tag db_schema_ref (tabelas tem_na_festa.*);
#   - as colunas das tabelas do Glue em analytics/tabelas.json (tnf_bronze.*);
#   - os oito campos com papel da "Especificação de Base de Dados" 3.0, seção
#     3.1 (pof_trends.bruto), com o mesmo tipo, tamanho, domínio e exemplo.
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
    papel = ("Papel na EBD" in col) ? limpa($(col["Papel na EBD"])) : ""
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

# --- 4. os oito campos com papel da EBD 3.0, seção 3.1 ------------------------------------------
# campo | papel | tipo | tamanho | obrigatório | domínio | exemplo
EBD="$(cat <<'EOF'
produto_id	1. Chave primária	inteiro	2	sim	Número estável, único, positivo e não nulo (1 a 10)	1
data_coleta	2. Campo de data	data	10	sim	Data da execução semanal, YYYY-MM-DD, fuso de São Paulo	2026-08-20
evento_associado	3. Categórico de domínio fechado	texto	60	sim	Um dos 12 eventos do calendário comercial (abaixo), definido pelo mes_pico	Páscoa / Outono
fator_sazonalidade	4. Numérico a discretizar	decimal	5,2	sim	Maior que zero; popularidade_pico ÷ popularidade_media, só com média maior que zero	2.75
produto_ibge	5. Texto livre a canonicalizar	texto	100	sim	Nome da categoria na POF/IBGE, sem espaços nas pontas	Bolos
termo_trends	6. Chave de cruzamento	texto	100	sim	Termo do mapa de busca que liga a categoria à série do Trends	barra de chocolate
consumo_kg_sp	7. Livre escolha	decimal	8,3	sim	Aquisição domiciliar per capita anual em kg, numérica, não nula e maior que zero	0.379
mes_pico	8. Livre escolha	inteiro	2	sim	Inteiro de 1 a 12, mês da coluna com a maior popularidade	3
EOF
)"
nomes=(campo papel tipo tamanho obrigatório domínio exemplo)
while IFS=$'\t' read -r -a esperado; do
  linha="$(awk -F'\t' -v c="${esperado[0]}" '$1 == "pof_trends.bruto" && $2 == c { print; exit }' "$WORK/dict.tsv")"
  if [[ -z "$linha" ]]; then
    err "falta o campo ${esperado[0]} da EBD (seção 3.1) em pof_trends.bruto."
    continue
  fi
  IFS=$'\t' read -r -a achado <<<"$linha"
  for i in 1 2 3 4 5 6; do
    if [[ "${achado[$((i + 1))]}" != "${esperado[$i]}" ]]; then
      err "pof_trends.bruto.${esperado[0]}: ${nomes[$i]} \"${achado[$((i + 1))]}\" difere da EBD 3.0, seção 3.1 (\"${esperado[$i]}\")."
    fi
  done
done <<<"$EBD"

if [[ ${#errors[@]} -gt 0 ]]; then
  echo "Dicionário de dados com problemas (${#errors[@]}):" >&2
  printf '  - %s\n' "${errors[@]}" >&2
  exit 2
fi
echo "Dicionário OK: $(cut -f1 "$WORK/sql.tsv" | sort -u | wc -l) tabelas do banco, $(cut -f1 "$WORK/glue.tsv" | sort -u | wc -l) do Glue e os 8 campos da EBD conferidos."
