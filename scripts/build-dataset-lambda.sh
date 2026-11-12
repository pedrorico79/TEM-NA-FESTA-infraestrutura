#!/usr/bin/env bash
# Empacota uma Lambda de coleta (10, seção 4): baixa o repositório do dataset
# na tag dataset_ref, instala as dependências de requirements-lambda.txt para
# Linux e Python 3.12 (pandas e numpy vêm do layer AWS SDK for pandas) e gera
# .infra/build/<lambda>-<tag>.zip. O zip de uma tag já gerado é reaproveitado,
# então a função só muda no Terraform quando a tag muda (source_code_hash).
#
# Uso: scripts/build-dataset-lambda.sh <pof-trends|tendencias> <tag> [url do repositório]
# Saída: o caminho do zip na saída padrão; 0 ok; 2 pré-requisito faltando.
set -euo pipefail

INFRA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=scripts/lib/common.sh
source "$INFRA_ROOT/scripts/lib/common.sh"

LAMBDA="${1:?informe a Lambda: pof-trends ou tendencias}"
REF="${2:?informe a tag do repositório do dataset (dataset_ref)}"
REPO_URL="${3:-https://github.com/pedrorico79/TEM-NA-FESTA-dataset}"
OUT_DIR="${TNF_BUILD_DIR:-$INFRA_ROOT/.infra/build}"
ZIP="$OUT_DIR/$LAMBDA-$REF.zip"

case "$LAMBDA" in
  pof-trends) MODULE=tnf_pof_trends ;;
  tendencias) MODULE=tnf_tendencias ;;
  *) die "$EXIT_PRECONDITION" "Lambda desconhecida: $LAMBDA (use pof-trends ou tendencias)." ;;
esac

if [[ -f "$ZIP" ]]; then
  printf '%s\n' "$ZIP"
  exit "$EXIT_OK"
fi

command -v git >/dev/null || die "$EXIT_PRECONDITION" "git não encontrado."
python3 -m pip --version >/dev/null 2>&1 ||
  die "$EXIT_PRECONDITION" "pip não encontrado. Instale com: sudo apt install -y python3-pip"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

git -c advice.detachedHead=false clone -q --depth 1 --branch "$REF" "$REPO_URL" "$WORK/repo" 2>"$WORK/git.err" ||
  die "$EXIT_PRECONDITION" "não foi possível baixar $REPO_URL na tag $REF: $(tail -n 1 "$WORK/git.err"). Confira dataset_ref."
[[ -f "$WORK/repo/script/$MODULE.py" && -f "$WORK/repo/requirements-lambda.txt" ]] ||
  die "$EXIT_PRECONDITION" "a tag $REF do dataset não tem script/$MODULE.py e requirements-lambda.txt; use uma tag com o handler da Lambda (10, seção 3)."

PKG="$WORK/pacote"
mkdir -p "$PKG"
cp "$WORK/repo/script/"tnf_*.py "$PKG/"
cp -r "$WORK/repo/bases-externas" "$PKG/"
python3 -m pip install -q --no-deps --no-compile --target "$PKG" \
  --platform manylinux2014_x86_64 --python-version 3.12 --implementation cp --only-binary=:all: \
  -r "$WORK/repo/requirements-lambda.txt" >"$WORK/pip.log" 2>&1 ||
  die "$EXIT_UNEXPECTED" "o pip não instalou as dependências da Lambda: $(tail -n 3 "$WORK/pip.log" | tr '\n' ' ')"

mkdir -p "$OUT_DIR"
# Zip reprodutível (ordem e datas fixas): o mesmo conteúdo gera o mesmo hash.
python3 - "$PKG" "$ZIP.tmp" <<'PY'
import os, sys, zipfile
raiz, destino = sys.argv[1], sys.argv[2]
arquivos = sorted(os.path.relpath(os.path.join(d, f), raiz) for d, _, fs in os.walk(raiz) for f in fs)
with zipfile.ZipFile(destino, "w", zipfile.ZIP_DEFLATED) as z:
    for nome in arquivos:
        info = zipfile.ZipInfo(nome, date_time=(2026, 1, 1, 0, 0, 0))
        info.external_attr = 0o644 << 16
        with open(os.path.join(raiz, nome), "rb") as f:
            z.writestr(info, f.read(), zipfile.ZIP_DEFLATED)
PY
mv "$ZIP.tmp" "$ZIP"
printf '%s\n' "$ZIP"
