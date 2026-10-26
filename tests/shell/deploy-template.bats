#!/usr/bin/env bats
# templates/deploy.yml (07, seções 4.4 e 4.5): os passos "Conferir a trava de
# prod" (C18, C19) e "Conferir as variáveis VITE_*" (C15, C16) rodados fora do
# GitHub, com as variáveis que o Actions passaria. A conferência no GitHub
# continua manual (tests/TRACEABILITY.md).

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  WORK="$BATS_TEST_TMPDIR"
  python3 - "$REPO/templates/deploy.yml" "$WORK" <<'EOF'
import sys, yaml
workflow = yaml.safe_load(open(sys.argv[1]))
names = {"Conferir a trava de prod": "guard.sh", "Conferir as variáveis VITE_*": "vite.sh"}
for step in workflow["jobs"]["deploy"]["steps"]:
    if step.get("name") in names:
        open(f"{sys.argv[2]}/{names[step['name']]}", "w").write(step["run"])
EOF
  export GITHUB_STEP_SUMMARY="$WORK/summary" RUNNER_TEMP="$WORK"
  : >"$GITHUB_STEP_SUMMARY"
}

guard() {
  ENV_NAME=$1 REF_TYPE=$2 REF_NAME=$3 REUSE_TAG=${4:-} run bash -e "$WORK/guard.sh"
}

vite() {
  cd "$WORK" || return
  REPO_VARS=$1 run bash -e "$WORK/vite.sh"
}

frontend_dockerfile() {
  printf 'FROM node:20-alpine AS build\nARG VITE_CNPJ\n  ARG VITE_API_URL\nARG VITE_OPCIONAL=x\nARG OUTRO\n' >"$WORK/Dockerfile"
}

# --- trava de prod ------------------------------------------------------------------

@test "C18: prod a partir de uma branch que não é a main falha com a mensagem de 07, 4.5" {
  guard prod branch feat/x
  [ "$status" -ne 0 ]
  [[ "$output" == *"Prod só aceita a branch main ou uma tag do Git. Você escolheu feat/x."* ]]
  grep -q "Você escolheu feat/x" "$GITHUB_STEP_SUMMARY"
}

@test "C18: a trava vale também com reuse_tag" {
  guard prod branch feat/x sha-abc1234
  [ "$status" -ne 0 ]
}

@test "C19: prod a partir da main segue" {
  guard prod branch main
  [ "$status" -eq 0 ]
}

@test "C19: prod a partir de uma tag do Git segue" {
  guard prod tag v1.0.0
  [ "$status" -eq 0 ]
}

@test "C19: dev a partir de qualquer branch segue" {
  guard dev branch feat/x
  [ "$status" -eq 0 ]
}

@test "reuse_tag fora da forma sha-xxxxxxx falha antes de qualquer coisa" {
  guard dev branch main dev
  [ "$status" -ne 0 ]
  [[ "$output" == *"reuse_tag deve ter a forma sha-xxxxxxx"* ]]
}

# --- variáveis VITE_* ---------------------------------------------------------------

@test "C15: ARG VITE_* sem valor padrão e sem variável no repositório falha citando a variável" {
  frontend_dockerfile
  vite '{"VITE_CNPJ":"12345678000199"}'
  [ "$status" -ne 0 ]
  [[ "$output" == *"Falta a variável VITE_API_URL no repositório do frontend"* ]]
  [[ "$output" == *"Nada foi construído nem publicado."* ]]
}

@test "C15: variável vazia conta como ausente" {
  frontend_dockerfile
  vite '{"VITE_CNPJ":"","VITE_API_URL":"/api/v1"}'
  [ "$status" -ne 0 ]
  [[ "$output" == *"Falta a variável VITE_CNPJ"* ]]
}

@test "C16: com todas as variáveis, viram build-args e aparecem no resumo" {
  frontend_dockerfile
  vite '{"VITE_CNPJ":"12345678000199","VITE_API_URL":"/api/v1"}'
  [ "$status" -eq 0 ]
  grep -qx 'VITE_CNPJ=12345678000199' "$WORK/build-args"
  grep -qx 'VITE_API_URL=/api/v1' "$WORK/build-args"
  grep -qF "| \`VITE_CNPJ\` | \`12345678000199\` |" "$GITHUB_STEP_SUMMARY"
  grep -qF "| \`VITE_OPCIONAL\` | (valor padrão do Dockerfile) |" "$GITHUB_STEP_SUMMARY"
}

@test "variável VITE_* do repositório sem ARG no Dockerfile é ignorada com aviso" {
  frontend_dockerfile
  vite '{"VITE_CNPJ":"1","VITE_API_URL":"/api/v1","VITE_SOBRA":"z"}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"VITE_SOBRA"*"ignorada"* ]]
  run grep -q VITE_SOBRA "$WORK/build-args"
  [ "$status" -ne 0 ]
}

@test "Dockerfile sem ARG VITE_* (backend) não exige nada" {
  printf 'FROM eclipse-temurin:21-jre-alpine\n' >"$WORK/Dockerfile"
  vite '{}'
  [ "$status" -eq 0 ]
  [ ! -s "$WORK/build-args" ]
}
