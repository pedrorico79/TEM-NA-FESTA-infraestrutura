#!/usr/bin/env bats
# Testes do `infra doctor` e do roteamento de comandos do `infra` (G1, G13).
# As ferramentas (terraform, aws, jq...) são simuladas: nenhuma chamada à AWS.

INFRA="$BATS_TEST_DIRNAME/../../infra"
COMMON="$BATS_TEST_DIRNAME/../../scripts/lib/common.sh"

setup() {
  FAKE="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$FAKE"
  # Utilitários reais de que o infra precisa.
  local u
  for u in bash dirname sed head grep uname timeout cat; do
    ln -s "$(command -v "$u")" "$FAKE/$u"
  done
  rm "$FAKE/uname"
  stub uname 'echo "6.6.0-microsoft-standard-WSL2"'
  stub terraform 'echo "Terraform v${TF_STUB_VERSION:-1.16.5}"; echo "on linux_amd64"'
  stub aws '
case "$1" in
  --version) echo "aws-cli/${AWS_STUB_VERSION:-2.37.12} Python/3.14 Linux/6.6 exe/x86_64" ;;
  configure) [[ -n "${AWS_STUB_REGION-us-east-1}" ]] && echo "${AWS_STUB_REGION-us-east-1}" || exit 1 ;;
  sts) if [[ "${AWS_STUB_STS:-ok}" == ok ]]; then echo 000000000000; else echo "An error occurred (ExpiredToken)" >&2; exit 255; fi ;;
esac'
  local t
  for t in jq curl make shellcheck tflint bats yamllint; do
    stub "$t" 'exit 0'
  done
}

# stub <nome> <corpo>: cria um executável simulado no PATH falso.
stub() {
  printf '#!%s\n%s\n' "$(command -v bash)" "$2" >"$FAKE/$1"
  chmod +x "$FAKE/$1"
}

doctor() {
  run env -i HOME="$BATS_TEST_TMPDIR" PATH="$FAKE" "$@" "$INFRA" doctor
}

@test "G1: com tudo instalado e credenciais válidas, lista as ferramentas e termina com 0" {
  doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"[ok]    rodando no WSL"* ]]
  [[ "$output" == *"[ok]    terraform 1.16.5"* ]]
  [[ "$output" == *"[ok]    aws-cli 2.37.12"* ]]
  [[ "$output" == *"[ok]    jq"* ]]
  [[ "$output" == *"[ok]    curl"* ]]
  [[ "$output" == *"[ok]    região us-east-1"* ]]
  [[ "$output" == *"credenciais do laboratório válidas"* ]]
  [[ "$output" == *"Tudo pronto."* ]]
}

@test "G1: ferramenta obrigatória ausente vira pendência com instrução, código 2" {
  rm "$FAKE/jq" "$FAKE/terraform"
  doctor
  [ "$status" -eq 2 ]
  [[ "$output" == *"[falta] jq: não encontrado. Instale com 'sudo apt install -y jq'."* ]]
  [[ "$output" == *"[falta] terraform: não encontrado"*"passo 2.2"* ]]
  [[ "$output" == *"2 pendência(s)"* ]]
}

@test "G1: ferramenta de desenvolvimento ausente é só aviso" {
  rm "$FAKE/bats"
  doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"[aviso] bats: não encontrado; só é necessário para desenvolver"* ]]
}

@test "G1: Terraform abaixo de 1.11 é recusado" {
  doctor TF_STUB_VERSION=1.10.5
  [ "$status" -eq 2 ]
  [[ "$output" == *"[falta] terraform 1.10.5: é preciso a versão 1.11.0 ou superior"* ]]
}

@test "G1: AWS CLI v1 é recusado" {
  doctor AWS_STUB_VERSION=1.33.0
  [ "$status" -eq 2 ]
  [[ "$output" == *"é preciso o AWS CLI v2"* ]]
}

@test "G1: credenciais vencidas viram pendência com o passo do guia" {
  doctor AWS_STUB_STS=expired
  [ "$status" -eq 2 ]
  [[ "$output" == *"[falta] credenciais da AWS ausentes, inválidas ou vencidas"*"passo 4"* ]]
}

@test "G1: região fora do laboratório e região ausente viram pendência" {
  doctor AWS_STUB_REGION=eu-west-1
  [ "$status" -eq 2 ]
  [[ "$output" == *"região eu-west-1: o laboratório só permite us-east-1 ou us-west-2"* ]]
  doctor AWS_STUB_REGION=
  [ "$status" -eq 2 ]
  [[ "$output" == *"região da AWS não configurada"* ]]
}

@test "G1: a região das variáveis de ambiente vale mais que a do aws configure" {
  doctor AWS_REGION=us-west-2 AWS_STUB_REGION=eu-west-1
  [ "$status" -eq 0 ]
  [[ "$output" == *"[ok]    região us-west-2"* ]]
}

@test "G13: caminhos em /mnt/<letra> são reconhecidos como disco do Windows" {
  source "$COMMON"
  is_windows_mount /mnt/c/Users/aluno/TEM-NA-FESTA-infraestrutura
  is_windows_mount /mnt/d
  ! is_windows_mount /home/aluno/projetos/TEM-NA-FESTA-infraestrutura
  ! is_windows_mount /mnt/wslg/x
}

@test "G13: fora de /mnt, o doctor confirma o repositório no sistema de arquivos do Linux" {
  doctor
  [[ "$output" == *"[ok]    repositório no sistema de arquivos do Linux"* ]]
}

@test "G13: clone em /mnt/c recebe a pendência com o que fazer (só no WSL)" {
  local win
  win="$(mktemp -d -p /mnt/c/Users/Public tnf-g13.XXXXXX 2>/dev/null)" || skip "sem /mnt/c gravável (fora do WSL)"
  mkdir -p "$win/scripts/lib"
  cp "$INFRA" "$win/infra"
  cp "$COMMON" "$win/scripts/lib/common.sh"
  run env -i HOME="$BATS_TEST_TMPDIR" PATH="$FAKE" "$win/infra" doctor
  rm -rf "$win"
  [ "$status" -eq 2 ]
  [[ "$output" == *"[falta] o repositório está em /mnt/c/"*"Clone-o dentro do sistema de arquivos do WSL, por exemplo em ~/projetos"* ]]
}

@test "infra --help lista os comandos" {
  run "$INFRA" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"doctor"* ]]
  [[ "$output" == *"down <env>"* ]]
}

@test "infra doctor --help descreve a saída" {
  run "$INFRA" doctor --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Saída: 0 tudo certo; 2 há pendências."* ]]
}

@test "comando ainda não implementado termina com código 2 e diz a etapa" {
  run "$INFRA" snapshot dev
  [ "$status" -eq 2 ]
  [[ "$output" == *"chega na etapa E4b"* ]]
}

@test "comando desconhecido termina com código 2" {
  run "$INFRA" deploy
  [ "$status" -eq 2 ]
  [[ "$output" == *"comando desconhecido: 'deploy'"* ]]
}

@test "version_ge compara versões" {
  source "$COMMON"
  version_ge 1.11.0 1.11.0
  version_ge 1.16.5 1.11.0
  version_ge 2.0.0 1.11.0
  ! version_ge 1.10.9 1.11.0
  ! version_ge 1.9 1.11.0
}
