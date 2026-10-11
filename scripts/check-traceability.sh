#!/usr/bin/env bash
# Confere a rastreabilidade dos testes (08, seção 7; 09, seção 1; G10):
# specs 03 a 09 × tests/TRACEABILITY.md × listas "Pronto quando" de 09.
#
# Uso: scripts/check-traceability.sh [--strict] [--specs <pasta>] [--table <arquivo>]
#   --strict   também recusa situação "pendente", verificador "a definir" e
#              "não aplicável nesta entrega" sem motivo (roda na E9).
#   --specs    pasta com os specs (padrão: specs/ na raiz do repositório).
#   --table    tabela de rastreabilidade (padrão: tests/TRACEABILITY.md).
#
# Códigos de saída (08, seção 4.3): 0 tudo certo; 1 erro inesperado;
# 2 a rastreabilidade tem problemas (cada um é listado com o que fazer).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPECS_DIR="$ROOT/specs"
TABLE="$ROOT/tests/TRACEABILITY.md"
STRICT=0

usage() {
  sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --strict) STRICT=1; shift ;;
    --specs) SPECS_DIR="${2:?--specs precisa de uma pasta}"; shift 2 ;;
    --table) TABLE="${2:?--table precisa de um arquivo}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERRO: opção desconhecida: $1 (use --help)" >&2; exit 2 ;;
  esac
done

if [[ ! -d "$SPECS_DIR" ]]; then
  echo "ERRO: pasta de specs não encontrada: $SPECS_DIR" >&2
  exit 2
fi
if [[ ! -f "$TABLE" ]]; then
  echo "ERRO: tabela de rastreabilidade não encontrada: $TABLE. Crie-a com as colunas ID, etapa, verificador e situação (08, seção 7)." >&2
  exit 2
fi

shopt -s nullglob
spec_files=("$SPECS_DIR"/0[3-9]-*.md)
plan_files=("$SPECS_DIR"/09-*.md)
shopt -u nullglob
if [[ ${#spec_files[@]} -eq 0 ]]; then
  echo "ERRO: nenhum spec 03 a 09 encontrado em $SPECS_DIR" >&2
  exit 2
fi
if [[ ${#plan_files[@]} -ne 1 ]]; then
  echo "ERRO: esperado exatamente um 09-*.md (plano) em $SPECS_DIR" >&2
  exit 2
fi
PLAN="${plan_files[0]}"
PLAN_NAME="$(basename "$PLAN")"
TABLE_NAME="$(basename "$TABLE")"

ID_RE='[TSQRCGP][0-9]+'

# 1. IDs dos specs: primeira coluna das tabelas sob títulos "Critérios de aceite".
declare -A spec_of=()
while IFS=$'\t' read -r id file; do
  [[ -n "$id" ]] || continue
  spec_of["$id"]="$(basename "$file")"
done < <(awk '
  FNR == 1 { inside = 0 }
  /^#/ { inside = ($0 ~ /Critérios de aceite/); next }
  inside && match($0, /^\|[ \t]*[TSQRCGP][0-9]+[ \t]*\|/) {
    id = substr($0, RSTART, RLENGTH); gsub(/[| \t]/, "", id)
    print id "\t" FILENAME
  }' "${spec_files[@]}")

# 2. Listas "Pronto quando" da seção "Etapas" de 09: etapa → texto da lista.
#    A lista vai do "Pronto quando:" até o fim da linha, mais os subitens
#    indentados logo abaixo (caso da E9). Um item "- **E4a – ...**" define a
#    própria etapa dentro de "### E4".
pronto_lines="$(awk '
  /^## / { in_steps = ($0 ~ /Etapas/); cont = 0; next }
  !in_steps { next }
  /^### / { if (match($0, /E[0-9]+[a-z]?/)) stage = substr($0, RSTART, RLENGTH); cont = 0; next }
  {
    if (cont && $0 ~ /^[ \t][ \t]+- /) { print cstage "\t" $0; next }
    cont = 0
    i = index($0, "Pronto quando:")
    if (i > 0) {
      st = stage
      if (match($0, /^- \*\*E[0-9]+[a-z]? /)) st = substr($0, 5, RLENGTH - 5)
      print st "\t" substr($0, i + length("Pronto quando:"))
      cont = 1; cstage = st
    }
  }' "$PLAN")"

declare -A stages_of=()   # ID → etapas de 09 que o citam (separadas por espaço)
declare -A valid_stage=()
while IFS=$'\t' read -r stage text; do
  [[ -n "$stage" ]] || continue
  valid_stage["$stage"]=1
  ids=()
  # Intervalos como "Q19 a Q21" são expandidos (G10 f).
  while read -r range; do
    [[ -n "$range" ]] || continue
    l1="${range:0:1}"; n1="${range%% a *}"; n1="${n1:1}"
    r2="${range##* a }"; l2="${r2:0:1}"; n2="${r2:1}"
    if [[ "$l1" == "$l2" && "$n1" -le "$n2" ]]; then
      for ((n = n1; n <= n2; n++)); do ids+=("$l1$n"); done
    fi
  done < <(grep -oE "\\b${ID_RE} a ${ID_RE}\\b" <<<"$text" || true)
  while read -r id; do
    [[ -n "$id" ]] && ids+=("$id")
  done < <(grep -oE "\\b${ID_RE}\\b" <<<"$text" || true)
  for id in "${ids[@]+"${ids[@]}"}"; do
    case " ${stages_of[$id]:-} " in
      *" $stage "*) ;;
      *) stages_of["$id"]="${stages_of[$id]:+${stages_of[$id]} }$stage" ;;
    esac
  done
done <<<"$pronto_lines"

if [[ ${#valid_stage[@]} -eq 0 ]]; then
  echo "ERRO: nenhuma lista \"Pronto quando\" encontrada na seção \"Etapas\" de $PLAN_NAME" >&2
  exit 2
fi

# 3. Tabela de rastreabilidade: | ID | etapa | verificador | situação |
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "${s//\`/}"; }

declare -A row_stage=() row_ver=() row_sit=()
errors=()
err() { errors+=("$1"); }

while IFS= read -r line; do
  [[ "$line" == \|* ]] || continue
  IFS='|' read -r _ c_id c_stage c_ver c_sit _ <<<"$line"
  id="$(trim "$c_id")"
  [[ "$id" =~ ^${ID_RE}$ ]] || continue
  if [[ -n "${row_stage[$id]+x}" ]]; then
    err "$id aparece em mais de uma linha de $TABLE_NAME. Deixe só uma."
    continue
  fi
  row_stage["$id"]="$(trim "$c_stage")"
  row_ver["$id"]="$(trim "$c_ver")"
  row_sit["$id"]="$(trim "$c_sit")"
done <"$TABLE"

NA_PREFIX='não aplicável nesta entrega'

# (a) ID dos specs sem linha na tabela; (c) ID que não aparece nas listas de 09.
for id in $(printf '%s\n' "${!spec_of[@]}" | sort -V); do
  if [[ -z "${stages_of[$id]:-}" ]]; then
    err "$id (${spec_of[$id]}) não aparece em nenhuma lista \"Pronto quando\" de $PLAN_NAME. Acrescente-o à etapa em que é verificado (09, seção 3) no mesmo PR."
  fi
  if [[ -z "${row_stage[$id]+x}" ]]; then
    err "$id (${spec_of[$id]}) não tem linha em $TABLE_NAME. Acrescente: | $id | ${stages_of[$id]:-<etapa>} | <verificador> | pendente |"
  fi
done

# (b) linhas da tabela; (d) etapa divergente; campos obrigatórios e situação.
for id in $(printf '%s\n' "${!row_stage[@]}" | sort -V); do
  if [[ -z "${spec_of[$id]:-}" ]]; then
    err "$id está em $TABLE_NAME, mas não existe em nenhuma tabela \"Critérios de aceite\" dos specs 03 a 09. Remova a linha ou corrija o ID."
    continue
  fi
  st="${row_stage[$id]}" ver="${row_ver[$id]}" sit="${row_sit[$id]}"
  if [[ -z "$st" ]]; then
    err "$id não tem etapa em $TABLE_NAME. Preencha com a etapa de 09: ${stages_of[$id]:-<etapa>}."
  elif [[ -z "${valid_stage[$st]:-}" ]]; then
    err "$id tem a etapa \"$st\", que não existe em $PLAN_NAME. Etapas válidas: $(printf '%s\n' "${!valid_stage[@]}" | sort -V | tr '\n' ' ')"
  elif [[ -n "${stages_of[$id]:-}" && " ${stages_of[$id]} " != *" $st "* ]]; then
    err "$id está na etapa $st em $TABLE_NAME, mas $PLAN_NAME o cita em: ${stages_of[$id]}. Corrija a tabela ou 09 no mesmo PR."
  fi
  if [[ -z "$ver" ]]; then
    err "$id não tem verificador em $TABLE_NAME. Informe o arquivo de teste, o teste bats ou \"manual: <procedimento>\"."
  elif [[ "$STRICT" -eq 1 && "${ver,,}" == "a definir" ]]; then
    err "$id tem verificador \"a definir\". No modo estrito o verificador precisa estar preenchido."
  fi
  case "$sit" in
    pendente)
      [[ "$STRICT" -eq 1 ]] && err "$id está \"pendente\". No modo estrito cada linha precisa estar \"verificado\" ou \"$NA_PREFIX: <motivo>\"." ;;
    verificado) ;;
    "$NA_PREFIX"|"$NA_PREFIX:"*)
      motive="${sit#"$NA_PREFIX"}"; motive="${motive#:}"; motive="$(trim "$motive")"
      [[ "$STRICT" -eq 1 && -z "$motive" ]] && err "$id está \"$NA_PREFIX\" sem motivo. Escreva \"$NA_PREFIX: <motivo>\"." ;;
    *)
      err "$id tem a situação \"$sit\". Use \"pendente\", \"verificado\" ou \"$NA_PREFIX: <motivo>\" (08, seção 7)." ;;
  esac
done

if [[ ${#errors[@]} -gt 0 ]]; then
  echo "Rastreabilidade com problemas (${#errors[@]}):" >&2
  printf '  - %s\n' "${errors[@]}" >&2
  exit 2
fi

total=${#spec_of[@]} done_n=0 pend_n=0 na_n=0
for id in "${!row_sit[@]}"; do
  case "${row_sit[$id]}" in
    verificado) done_n=$((done_n + 1)) ;;
    pendente) pend_n=$((pend_n + 1)) ;;
    *) na_n=$((na_n + 1)) ;;
  esac
done
mode="normal"; [[ "$STRICT" -eq 1 ]] && mode="estrito"
echo "Rastreabilidade OK (modo $mode): $total IDs; $done_n verificados, $pend_n pendentes, $na_n não aplicáveis."
