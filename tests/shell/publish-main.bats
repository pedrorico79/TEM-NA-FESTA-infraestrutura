#!/usr/bin/env bats
# scripts/publish-main.sh (08, seção 7): monta a main limpa a partir da
# develop, num repositório Git temporário.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../scripts/publish-main.sh"
  R="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$R" && cd "$R"
  git init -q -b main
  git config user.name teste
  git config user.email teste@exemplo.invalid
  echo antigo >infra
  git add . && git commit -q -m "main inicial"
  git switch -q -c develop
  mkdir -p specs tests/shell scripts
  echo novo >infra
  echo spec >specs/00.md
  echo t >tests/shell/a.bats
  echo m >Makefile
  echo s >scripts/preflight.sh
  printf '# comentário\nspecs/\ntests/\nMakefile\n.main-ignore\nnao-existe/\n' >.main-ignore
  git add . && git commit -q -m "develop"
}

@test "publish-main: a branch de publicação tem a develop sem os caminhos do .main-ignore" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Branch release/main atualizada"* ]]
  [ "$(git ls-tree -r --name-only release/main | sort | tr '\n' ' ')" = "infra scripts/preflight.sh " ]
  [ "$(git show release/main:infra)" = novo ]
}

@test "publish-main: o commit tem a main e a develop como pais e nada muda na pasta de trabalho" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(git rev-parse release/main^1)" = "$(git rev-parse main)" ]
  [ "$(git rev-parse release/main^2)" = "$(git rev-parse develop)" ]
  [ "$(git branch --show-current)" = develop ]
  [ -z "$(git status --porcelain)" ]
}

@test "publish-main: uma segunda publicação avança a branch (a anterior é ancestral, sem push forçado)" {
  "$SCRIPT"
  primeira="$(git rev-parse release/main)"
  echo mais >infra
  git commit -q -am "mais uma mudança"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  git merge-base --is-ancestor "$primeira" release/main
  [ "$(git rev-parse release/main^3)" = "$primeira" ]
}

@test "publish-main: repetir sem mudança na develop não cria outro commit" {
  "$SCRIPT"
  primeira="$(git rev-parse release/main)"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nada a publicar"* ]]
  [ "$(git rev-parse release/main)" = "$primeira" ]
}

@test "publish-main: sem diferença de conteúdo, não cria commit" {
  "$SCRIPT"
  git branch -q -f main release/main
  git branch -q -D release/main
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nada a publicar"* ]]
  ! git rev-parse -q --verify release/main
}

@test "publish-main: origem sem .main-ignore é recusada com código 2" {
  run "$SCRIPT" --source main
  [ "$status" -eq 2 ]
  [[ "$output" == *"não tem o arquivo .main-ignore"* ]]
}
