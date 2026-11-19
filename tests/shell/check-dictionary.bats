#!/usr/bin/env bats
# D12 (10, seção 11): scripts/check-dictionary.sh recusa o dicionário que
# diverge do script do banco, das tabelas do Glue ou do bruto da coleta.
# Usa o dicionário e o tabelas.json reais e um script SQL de exemplo.

SCRIPT="$BATS_TEST_DIRNAME/../../scripts/check-dictionary.sh"
REPO="$BATS_TEST_DIRNAME/../.."

setup() {
  W="$BATS_TEST_TMPDIR"
  cp "$REPO/docs/dicionario-de-dados.md" "$W/dict.md"
  cp "$REPO/analytics/tabelas.json" "$W/tabelas.json"
  # Script do banco montado a partir do próprio dicionário: as 12 tabelas com
  # as colunas e os tipos descritos, no formato do TEM-NA-FESTA-database.
  awk -F'|' '
    function limpa(s) { gsub(/`/, "", s); gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    /^### `tem_na_festa\./ { if (t != "") print ");"; t = $0; sub(/^### `tem_na_festa\./, "", t); sub(/`.*/, "", t); print "CREATE TABLE " t " ("; cab = 0; next }
    /^#/ { if (t != "") print ");"; t = ""; next }
    t != "" && /^\|/ { cab++; if (cab <= 2) next; print "    " limpa($2) " " limpa($3) "," }
    END { if (t != "") print ");" }
  ' "$W/dict.md" >"$W/schema.sql"
}

check() {
  run "$SCRIPT" --dict "$W/dict.md" --sql "$W/schema.sql" --tables "$W/tabelas.json"
}

@test "D12: dicionário, script do banco, Glue e bruto da coleta de acordo passam" {
  check
  [ "$status" -eq 0 ]
  [[ "$output" == *"12 tabelas do banco, 6 do Glue e os 10 campos do bruto da coleta"* ]]
}

@test "D12: coluna a mais no script do banco é recusada" {
  sed -i 's/^CREATE TABLE produto (/CREATE TABLE produto (\n    peso_gramas INT,/' "$W/schema.sql"
  check
  [ "$status" -eq 2 ]
  [[ "$output" == *"falta a coluna peso_gramas (INT) da tabela tem_na_festa.produto"* ]]
}

@test "D12: coluna a menos no dicionário é recusada" {
  sed -i '/^| `instagram` |/d' "$W/dict.md"
  check
  [ "$status" -eq 2 ]
  [[ "$output" == *"falta a coluna instagram (VARCHAR(50)) da tabela tem_na_festa.cliente"* ]]
}

@test "D12: tipo diferente é recusado" {
  sed -i 's/^    cep VARCHAR(8),/    cep VARCHAR(9),/' "$W/schema.sql"
  check
  [ "$status" -eq 2 ]
  [[ "$output" == *"tem_na_festa.endereco.cep tem o tipo \"VARCHAR(8)\" no dicionário, mas \"VARCHAR(9)\""* ]]
}

@test "D12: campo do resumo que falta no bruto da coleta é recusado" {
  sed -i '/Mês de 1 a 12; em empate prevalece o primeiro mês cronológico/d' "$W/dict.md"
  check
  [ "$status" -eq 2 ]
  [[ "$output" == *"falta o campo mes_pico em tendencias_produtos.bruto"* ]]
}

@test "D12: campo do bruto da coleta com domínio em branco é recusado" {
  sed -i 's/| Atualmente fixo como `Sazonalidade Comercial` |/| |/' "$W/dict.md"
  check
  [ "$status" -eq 2 ]
  [[ "$output" == *"tendencias_produtos.bruto.tipo_feriado_pico: domínio em branco no dicionário"* ]]
}

@test "D12: dicionário sem o bruto da coleta é recusado" {
  sed -i 's/^### `tendencias_produtos.bruto`/### Bruto/' "$W/dict.md"
  check
  [ "$status" -eq 2 ]
  [[ "$output" == *"a tabela tendencias_produtos.bruto não está no dicionário"* ]]
}

@test "coluna do Glue sem linha no dicionário é recusada" {
  jq '.logs_auth.novo_campo = "string"' "$W/tabelas.json" >"$W/t.json" && mv "$W/t.json" "$W/tabelas.json"
  check
  [ "$status" -eq 2 ]
  [[ "$output" == *"falta a coluna novo_campo (string) da tabela tnf_bronze.logs_auth"* ]]
}

@test "linha do dicionário sem coluna na fonte é recusada" {
  sed -i '/^    nome VARCHAR(50),$/d' "$W/schema.sql"
  check
  [ "$status" -eq 2 ]
  [[ "$output" == *"o dicionário descreve tem_na_festa."*".nome, que não existe na fonte (o script do banco)"* ]]
}
