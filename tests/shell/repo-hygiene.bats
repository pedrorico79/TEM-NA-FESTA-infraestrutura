#!/usr/bin/env bats
# Testes da higiene do repositório verificada pelo `make check` (G3, G12, G14).
# Cada teste monta um repositório Git temporário com o Makefile, o .gitignore
# e o .gitattributes reais.

REPO_ROOT="$BATS_TEST_DIRNAME/../.."

setup() {
  WORK="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$WORK"
  cp "$REPO_ROOT/Makefile" "$REPO_ROOT/.gitignore" "$REPO_ROOT/.gitattributes" "$WORK/"
  cd "$WORK"
  git init -q
  git config user.email "teste@example.invalid"
  git config user.name "teste"
  git config core.autocrlf false
  git add -A
  git commit -q -m "base"
}

@test "G3: repositório sem arquivos ignorados versionados passa" {
  run make -s check-ignored
  [ "$status" -eq 0 ]
}

@test "G3: secrets.env versionado à força é recusado, nomeando o arquivo" {
  echo "CHAVE=" >secrets.env
  git add -f secrets.env
  run make -s check-ignored
  [ "$status" -ne 0 ]
  [[ "$output" == *"secrets.env"* ]]
}

@test "G3: chave .pem e state versionados à força são recusados" {
  mkdir -p .keys envs/dev
  echo "x" >.keys/dev.pem
  echo "{}" >envs/dev/terraform.tfstate
  git add -f .keys/dev.pem envs/dev/terraform.tfstate
  run make -s check-ignored
  [ "$status" -ne 0 ]
  [[ "$output" == *".keys/dev.pem"* ]]
  [[ "$output" == *"envs/dev/terraform.tfstate"* ]]
}

@test "G12: o .gitignore não exclui o .terraform.lock.hcl" {
  run git check-ignore -q --no-index envs/dev/.terraform.lock.hcl
  [ "$status" -ne 0 ]
  run make -s check-lock
  [ "$status" -eq 0 ]
}

@test "G12: raiz do Terraform sem lock versionado é recusada" {
  mkdir -p envs/dev
  echo 'terraform {}' >envs/dev/main.tf
  git add envs/dev/main.tf
  run make -s check-lock
  [ "$status" -ne 0 ]
  [[ "$output" == *"envs/dev"* ]]
  echo '# lock' >envs/dev/.terraform.lock.hcl
  git add envs/dev/.terraform.lock.hcl
  run make -s check-lock
  [ "$status" -eq 0 ]
}

@test "G12: .gitignore que exclui o lock é recusado" {
  echo '.terraform.lock.hcl' >>.gitignore
  run make -s check-lock
  [ "$status" -ne 0 ]
  [[ "$output" == *"exclui o .terraform.lock.hcl"* ]]
}

@test "G14: o .gitattributes converte um script CRLF para LF ao versionar" {
  printf '#!/usr/bin/env bash\r\necho oi\r\n' >script.sh
  git add script.sh
  run git ls-files --eol script.sh
  [[ "$output" == "i/lf "* ]]
}

@test "G14: script CRLF que escapa do .gitattributes é recusado, nomeando o arquivo" {
  echo 'legado.sh -text' >>.gitattributes
  printf '#!/usr/bin/env bash\r\necho oi\r\n' >legado.sh
  git add .gitattributes legado.sh
  git commit -q -m "crlf"
  run make -s check-eol
  [ "$status" -ne 0 ]
  [[ "$output" == *"legado.sh"* ]]
}

@test "G14: repositório só com LF passa" {
  run make -s check-eol
  [ "$status" -eq 0 ]
}
