#!/usr/bin/env bats
# G4 (08, seção 9): envs/dev e envs/prod diferem apenas no terraform.tfvars e
# na chave do state.

ENVS="$BATS_TEST_DIRNAME/../../envs"

@test "G4: dev e prod têm os mesmos arquivos versionados" {
  run diff <(cd "$ENVS/dev" && git ls-files | sort) <(cd "$ENVS/prod" && git ls-files | sort)
  [ "$status" -eq 0 ]
}

@test "G4: os arquivos .tf de dev e prod são iguais, exceto o backend.tf" {
  local f
  for f in "$ENVS"/dev/*.tf; do
    [[ "$(basename "$f")" == backend.tf ]] && continue
    run diff "$f" "$ENVS/prod/$(basename "$f")"
    [ "$status" -eq 0 ]
  done
}

@test "G4: o backend.tf difere só na chave do state" {
  run diff <(sed 's#envs/dev/#envs/ENV/#' "$ENVS/dev/backend.tf") <(sed 's#envs/prod/#envs/ENV/#' "$ENVS/prod/backend.tf")
  [ "$status" -eq 0 ]
  grep -q 'key *= "envs/dev/terraform.tfstate"' "$ENVS/dev/backend.tf"
  grep -q 'key *= "envs/prod/terraform.tfstate"' "$ENVS/prod/backend.tf"
}

@test "G4: cada terraform.tfvars define o próprio env" {
  grep -Eq '^env *= *"dev"$' "$ENVS/dev/terraform.tfvars"
  grep -Eq '^env *= *"prod"$' "$ENVS/prod/terraform.tfvars"
}

@test "03, seção 3.8: as quatro variáveis sem padrão estão preenchidas nos dois ambientes (a partir da E4a)" {
  local e v
  for e in dev prod; do
    for v in dockerhub_namespace db_schema_repo_url db_schema_ref db_schema_path; do
      grep -Eq "^$v *= *\"[^\"]+\"$" "$ENVS/$e/terraform.tfvars"
    done
  done
}

@test "03, seção 3.4: a mensageria está desligada nos dois ambientes até a E8" {
  local e
  for e in dev prod; do
    grep -Eq '^ *messaging *= *0$' "$ENVS/$e/terraform.tfvars"
  done
}
