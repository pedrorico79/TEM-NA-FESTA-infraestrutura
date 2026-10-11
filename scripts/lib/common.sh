#!/usr/bin/env bash
# Funções comuns do infra e dos scripts de apoio (08, seções 2 e 4.3).
# Uso: source "scripts/lib/common.sh". Não imprime segredos.

# Códigos de saída (08, seção 4.3).
readonly EXIT_OK=0
readonly EXIT_UNEXPECTED=1
readonly EXIT_PRECONDITION=2
readonly EXIT_TIMEOUT=3
export EXIT_OK EXIT_UNEXPECTED EXIT_PRECONDITION EXIT_TIMEOUT

# Linhas de resultado padronizadas.
say_ok()   { printf '[ok]    %s\n' "$*"; }
say_warn() { printf '[aviso] %s\n' "$*"; }
say_miss() { printf '[falta] %s\n' "$*"; }
say_info() { printf '[info]  %s\n' "$*"; }

# die <código> <mensagem>: termina com a mensagem do que aconteceu e do que fazer.
die() {
  local code="$1"; shift
  printf 'ERRO: %s\n' "$*" >&2
  exit "$code"
}

# is_windows_mount <caminho>: verdadeiro se o caminho está no disco do Windows
# montado pelo WSL (/mnt/<letra>/...), onde permissões 600 não funcionam (5.1).
is_windows_mount() {
  case "$1" in
    /mnt/[a-zA-Z] | /mnt/[a-zA-Z]/*) return 0 ;;
    *) return 1 ;;
  esac
}

# is_wsl: verdadeiro se está rodando dentro do WSL.
is_wsl() {
  uname -r 2>/dev/null | grep -qi microsoft
}

# version_ge <versão> <mínima>: verdadeiro se versão >= mínima (formato x.y.z).
version_ge() {
  local IFS=.
  local -a a b
  read -r -a a <<<"$1"
  read -r -a b <<<"$2"
  local i
  for i in 0 1 2; do
    local x="${a[i]:-0}" y="${b[i]:-0}"
    x="${x%%[!0-9]*}"; y="${y%%[!0-9]*}"
    x="${x:-0}"; y="${y:-0}"
    if ((10#$x > 10#$y)); then return 0; fi
    if ((10#$x < 10#$y)); then return 1; fi
  done
  return 0
}
