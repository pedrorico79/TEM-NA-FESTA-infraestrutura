#!/usr/bin/env bats
# Testes do scripts/check-traceability.sh (08, seção 7; G10 a a h).
# Usa specs e tabela de exemplo, gerados em uma pasta temporária.

SCRIPT="$BATS_TEST_DIRNAME/../../scripts/check-traceability.sh"

setup() {
  SPECS="$BATS_TEST_TMPDIR/specs"
  TABLE="$BATS_TEST_TMPDIR/TRACEABILITY.md"
  mkdir -p "$SPECS"

  cat >"$SPECS/03-contrato.md" <<'EOF'
# 03 – Contrato
## 6. Critérios de aceite: testes do contrato
| # | Caso | Esperado |
|---|---|---|
| T1 | caso 1 | recusa |
| T2 | caso 2 | recusa |
| T3 | caso 3 | recusa |
## 7. Decisões
| T9 | fora de "Critérios de aceite" | não conta |
EOF

  cat >"$SPECS/04-subida.md" <<'EOF'
# 04 – Subida
## 11. Critérios de aceite (verificáveis)
| # | Cenário | Esperado |
|---|---|---|
| S1 | cenário 1 | ok |
| S2 | cenário 2 | ok |
| S3 | cenário 3 | ok |
EOF

  write_plan "  - S3 (réplicas);"
  write_table <<'EOF'
| T1 | E0 | tests/contract/T1.tftest.hcl | pendente |
| T2 | E1 | tests/contract/T2.tftest.hcl | verificado |
| T3 | E4a | manual: conferência no laboratório | pendente |
| S1 | E1 | tests/contract/S1.tftest.hcl | pendente |
| S2 | E4a | manual: conferência no laboratório | pendente |
| S3 | E9 | manual: conferência no laboratório | pendente |
| P1 | E9 | manual: revisão de 09 | pendente |
EOF
}

# write_plan <linha da lista da E9 com S3>
write_plan() {
  cat >"$SPECS/09-plano.md" <<EOF
# 09 – Plano
## 3. Etapas
### E0 – Preparação
- **Entrega:** o bucket de artefatos (não confundir com o teste S3).
- **Pronto quando:** T1, P1.
### E1 – Contrato
- **Pronto quando:** T2 a T3, S1.
### E4 – Dividida
- **E4a – Nós:** módulos. **Pronto quando:** S2 e T3.
### E9 – Aceite final
- **Pronto quando:**
$1
  - P1 de novo.
- **Outro item:** T1 fora da lista.
## 7. Critérios de aceite do plano
| # | Cenário | Esperado |
|---|---|---|
| P1 | cada etapa | tem entrega |
EOF
}

# write_table: lê as linhas da tabela pela entrada padrão.
write_table() {
  {
    echo '| ID | Etapa | Verificador | Situação |'
    echo '|---|---|---|---|'
    cat
  } >"$TABLE"
}

check() {
  run "$SCRIPT" --specs "$SPECS" --table "$TABLE" "$@"
}

@test "G10a: specs e tabela corretos passam" {
  check
  [ "$status" -eq 0 ]
  [[ "$output" == *"Rastreabilidade OK"* ]]
  [[ "$output" == *"7 IDs"* ]]
}

@test "G10b: ID dos specs sem linha na tabela é recusado" {
  sed -i '/^| S1 |/d' "$TABLE"
  check
  [ "$status" -eq 2 ]
  [[ "$output" == *"S1 (04-subida.md) não tem linha"* ]]
  [[ "$output" == *"Acrescente: | S1 | E1 |"* ]]
}

@test "G10c: linha da tabela com ID inexistente nos specs é recusada" {
  echo '| T99 | E0 | tests/contract/T99.tftest.hcl | pendente |' >>"$TABLE"
  check
  [ "$status" -eq 2 ]
  [[ "$output" == *"T99 está em TRACEABILITY.md, mas não existe"* ]]
}

@test "G10c: tabela fora de \"Critérios de aceite\" não conta como ID dos specs" {
  echo '| T9 | E0 | tests/contract/T9.tftest.hcl | pendente |' >>"$TABLE"
  check
  [ "$status" -eq 2 ]
  [[ "$output" == *"T9 está em TRACEABILITY.md, mas não existe"* ]]
}

@test "G10d: ID dos specs que não aparece nas etapas de 09 é recusado" {
  sed -i 's/\*\*Pronto quando:\*\* S2 e T3\./**Pronto quando:** T3./' "$SPECS/09-plano.md"
  check
  [ "$status" -eq 2 ]
  [[ "$output" == *"S2 (04-subida.md) não aparece em nenhuma lista \"Pronto quando\""* ]]
}

@test "G10e: linha com etapa diferente da de 09 é recusada" {
  sed -i 's/^| T2 | E1 |/| T2 | E0 |/' "$TABLE"
  check
  [ "$status" -eq 2 ]
  [[ "$output" == *"T2 está na etapa E0"* ]]
  [[ "$output" == *"cita em: E1"* ]]
}

@test "G10e: etapa que não existe em 09 é recusada" {
  sed -i 's/^| T2 | E1 |/| T2 | E7 |/' "$TABLE"
  check
  [ "$status" -eq 2 ]
  [[ "$output" == *"T2 tem a etapa \"E7\", que não existe"* ]]
}

@test "G10f: intervalo é expandido e ID citado em duas etapas aceita qualquer uma" {
  # T2 só aparece dentro do intervalo "T2 a T3"; T3 está na E1 e na E4a.
  check
  [ "$status" -eq 0 ]
  sed -i 's/^| T3 | E4a |/| T3 | E1 |/' "$TABLE"
  check
  [ "$status" -eq 0 ]
}

@test "G10g: modo normal aceita pendente, \"a definir\" e não aplicável com ou sem motivo" {
  write_table <<'EOF'
| T1 | E0 | tests/contract/T1.tftest.hcl | pendente |
| T2 | E1 | a definir | verificado |
| T3 | E4a | manual: conferência no laboratório | não aplicável nesta entrega |
| S1 | E1 | tests/contract/S1.tftest.hcl | não aplicável nesta entrega: sem a configuração |
| S2 | E4a | manual: conferência no laboratório | verificado |
| S3 | E9 | manual: conferência no laboratório | verificado |
| P1 | E9 | manual: revisão de 09 | verificado |
EOF
  check
  [ "$status" -eq 0 ]
}

@test "G10g: --strict recusa pendente, \"a definir\" e não aplicável sem motivo, e aceita com motivo" {
  write_table <<'EOF'
| T1 | E0 | tests/contract/T1.tftest.hcl | pendente |
| T2 | E1 | a definir | verificado |
| T3 | E4a | manual: conferência no laboratório | não aplicável nesta entrega |
| S1 | E1 | tests/contract/S1.tftest.hcl | não aplicável nesta entrega: sem a configuração |
| S2 | E4a | manual: conferência no laboratório | verificado |
| S3 | E9 | manual: conferência no laboratório | verificado |
| P1 | E9 | manual: revisão de 09 | verificado |
EOF
  check --strict
  [ "$status" -eq 2 ]
  [[ "$output" == *"T1 está \"pendente\""* ]]
  [[ "$output" == *"T2 tem verificador \"a definir\""* ]]
  [[ "$output" == *"T3 está \"não aplicável nesta entrega\" sem motivo"* ]]
  [[ "$output" != *"S1 "* ]]
  [[ "$output" == *"(3)"* ]]
}

@test "G10g: --strict passa quando tudo está verificado ou não aplicável com motivo" {
  sed -i 's/| pendente |$/| verificado |/' "$TABLE"
  check --strict
  [ "$status" -eq 0 ]
  [[ "$output" == *"modo estrito"* ]]
}

@test "G10h: \"S3\" fora das listas \"Pronto quando\" não conta como citação do teste S3" {
  write_plan "  - réplicas conferidas;"
  check
  [ "$status" -eq 2 ]
  [[ "$output" == *"S3 (04-subida.md) não aparece em nenhuma lista \"Pronto quando\""* ]]
}

@test "G10: linha sem verificador é recusada" {
  sed -i 's/^| S1 | E1 | tests\/contract\/S1.tftest.hcl |/| S1 | E1 |  |/' "$TABLE"
  check
  [ "$status" -eq 2 ]
  [[ "$output" == *"S1 não tem verificador"* ]]
}

@test "G10: linha sem etapa é recusada" {
  sed -i 's/^| S1 | E1 |/| S1 |  |/' "$TABLE"
  check
  [ "$status" -eq 2 ]
  [[ "$output" == *"S1 não tem etapa"* ]]
}

@test "G10: ID repetido na tabela é recusado" {
  echo '| T1 | E0 | tests/contract/T1.tftest.hcl | pendente |' >>"$TABLE"
  check
  [ "$status" -eq 2 ]
  [[ "$output" == *"T1 aparece em mais de uma linha"* ]]
}

@test "G10: situação fora dos três valores é recusada" {
  sed -i 's/^\(| S1 | E1 | [^|]*|\) pendente |/\1 feito |/' "$TABLE"
  check
  [ "$status" -eq 2 ]
  [[ "$output" == *"S1 tem a situação \"feito\""* ]]
}

@test "G10: tabela ausente termina com código 2" {
  rm "$TABLE"
  check
  [ "$status" -eq 2 ]
  [[ "$output" == *"tabela de rastreabilidade não encontrada"* ]]
}
