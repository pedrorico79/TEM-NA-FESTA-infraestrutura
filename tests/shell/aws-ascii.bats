#!/usr/bin/env bats
# A API do EC2 recusa caracteres fora do ASCII nas descrições de security
# groups e de regras (erro visto no laboratório na E3). Fora dos comentários,
# os módulos que criam recursos de rede não podem ter acentos.

MODULES="$BATS_TEST_DIRNAME/../../modules"

@test "network e security: só ASCII fora dos comentários" {
  local f
  for f in "$MODULES"/network/main.tf "$MODULES"/security/main.tf; do
    run bash -c "grep -nP '[^\x00-\x7F]' '$f' | grep -vP '^\d+:\s*#'"
    [ -z "$output" ]
  done
}
