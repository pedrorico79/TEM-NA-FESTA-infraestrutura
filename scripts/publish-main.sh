#!/usr/bin/env bash
# Monta a main "limpa" a partir da develop (08, seção 7): a mesma árvore, sem
# os caminhos de desenvolvimento listados em .main-ignore (specs, testes,
# Makefile, CI). O resultado é um commit na branch de publicação, com a main e
# a develop como pais; a main só muda pelo pull request dessa branch.
#
# Uso: scripts/publish-main.sh [--source <ref>] [--target <ref>] [--branch <nome>]
#   --source   de onde vem o conteúdo (padrão: develop)
#   --target   a branch publicada (padrão: origin/main, ou main sem o remoto)
#   --branch   a branch local que recebe o commit (padrão: release/main)
# Não troca de branch, não mexe na pasta de trabalho e não faz push.
# Códigos de saída: 0 feito ou nada a publicar; 2 uso ou pré-condição.
set -euo pipefail

SOURCE=develop
TARGET=""
BRANCH=release/main
IGNORE_FILE=.main-ignore

die() {
  echo "ERRO: $*" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source) SOURCE="${2:?--source pede um valor}"; shift 2 ;;
    --target) TARGET="${2:?--target pede um valor}"; shift 2 ;;
    --branch) BRANCH="${2:?--branch pede um valor}"; shift 2 ;;
    -h | --help) sed -n '2,12s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *) die "opção desconhecida: $1 (veja --help)" ;;
  esac
done

cd "$(git rev-parse --show-toplevel)"

if [[ -z "$TARGET" ]]; then
  if git rev-parse -q --verify origin/main >/dev/null; then TARGET=origin/main; else TARGET=main; fi
fi
src="$(git rev-parse -q --verify "$SOURCE^{commit}")" || die "não existe a referência de origem '$SOURCE'."
dst="$(git rev-parse -q --verify "$TARGET^{commit}")" || die "não existe a referência publicada '$TARGET'."
list="$(git show "$src:$IGNORE_FILE" 2>/dev/null)" || die "$SOURCE não tem o arquivo $IGNORE_FILE."

tmp_index="$(mktemp)"
trap 'rm -f "$tmp_index"' EXIT
export GIT_INDEX_FILE="$tmp_index"
git read-tree "$src"
while IFS= read -r path; do
  path="${path%%#*}"
  path="${path%"${path##*[![:space:]]}"}"
  [[ -n "$path" ]] || continue
  git rm -r -q --cached --ignore-unmatch -- "${path%/}"
done <<<"$list"
tree="$(git write-tree)"
unset GIT_INDEX_FILE

if [[ "$tree" == "$(git rev-parse "$dst^{tree}")" ]]; then
  echo "Nada a publicar: $TARGET já tem o conteúdo de $SOURCE sem os caminhos de $IGNORE_FILE."
  exit 0
fi

short="$(git rev-parse --short "$src")"
commit="$(git commit-tree "$tree" -p "$dst" -p "$src" -m "chore: publica a main a partir da develop ($short)")"
git update-ref "refs/heads/$BRANCH" "$commit"

echo "Branch $BRANCH atualizada ($(git rev-parse --short "$commit")): $SOURCE ($short) sem os caminhos de $IGNORE_FILE."
echo "Envie com 'git push -f origin $BRANCH' e abra o pull request de $BRANCH para a main."
