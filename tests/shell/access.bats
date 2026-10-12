#!/usr/bin/env bats
# G24 (08, seção 5.6): infra access e infra ssh com aws, terraform, curl e
# ssh-keygen simulados.

load fake_aws

setup() {
  fake_setup
  touch "$FIX/buckets/$STATE_BUCKET"
  session_json 0
  KEY="$REPO/.keys/dev.pem"
}

authorized() {
  local c json='{"SecurityGroupRules":['
  local sep=""
  for c in "$@"; do
    json="$json$sep{\"IsEgress\":false,\"FromPort\":22,\"ToPort\":22,\"CidrIpv4\":\"$c\"}"
    sep=","
  done
  echo "$json]}" >"$FIX/aws/sg-rules.json"
}

access() { run "$REPO/infra" access dev "$@"; }

# --- (a) chave ----------------------------------------------------------------------

@test "G24a: chave ausente é recriada a partir do state, com permissão 600, sem perguntar" {
  authorized "203.0.113.10/32"
  access </dev/null
  [ "$status" -eq 0 ]
  [ -f "$KEY" ]
  [ "$(stat -c %a "$KEY")" = 600 ]
  [[ "$output" == *"chave SSH recriada a partir do state"* ]]
  [[ "$output" != *"[s/N]"* ]]
}

@test "G24a: chave presente e correta não é tocada" {
  authorized "203.0.113.10/32"
  mkdir -p "$REPO/.keys"
  cp "$FIX/key" "$KEY"
  chmod 600 "$KEY"
  touch -d '2026-01-01' "$KEY"
  access </dev/null
  [ "$status" -eq 0 ]
  [ "$(stat -c %y "$KEY" | cut -c1-10)" = 2026-01-01 ]
  [ ! -f "$KEY.anterior" ]
}

@test "G24a: chave de outro ambiente é trocada e a antiga guardada como .pem.anterior" {
  authorized "203.0.113.10/32"
  mkdir -p "$REPO/.keys"
  printf 'PUB:ssh-ed25519 AAAAchave-antiga\n' >"$KEY"
  access </dev/null
  [ "$status" -eq 0 ]
  grep -q 'AAAAchave-antiga' "$KEY.anterior"
  grep -q 'AAAAchave-atual' "$KEY"
  [[ "$output" == *"era de outro ambiente"* ]]
}

@test "G24a: clone em /mnt/c é recusado (só no WSL)" {
  local win
  win="$(mktemp -d -p /mnt/c/Users/Public tnf-g24.XXXXXX 2>/dev/null)" || skip "sem /mnt/c gravável (fora do WSL)"
  cp -r "$REPO"/. "$win"/
  run "$win/infra" access dev </dev/null
  rm -rf "$win"
  [ "$status" -eq 2 ]
  [[ "$output" == *"no disco do Windows"* ]]
}

@test "G24: ambiente que não está no ar termina com código 2" {
  touch "$FIX/no-state"
  access </dev/null
  [ "$status" -eq 2 ]
  [[ "$output" == *"não está no ar"* ]]
}

# --- (b) IP -------------------------------------------------------------------------

@test "G24b: IP atual já coberto: nada acontece" {
  authorized "203.0.113.0/24"
  access </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"já está autorizado"* ]]
  ! terraform_calls | grep -Eq " plan | apply "
}

@test "G24b: IP não coberto mostra autorizado e atual; N não aplica nada" {
  authorized "198.51.100.20/32"
  access <<<"N"
  [ "$status" -eq 2 ]
  [[ "$output" == *"autorizado no bastion: 198.51.100.20/32"* ]]
  [[ "$output" == *"seu IP atual: 203.0.113.10"* ]]
  ! terraform_calls | grep -Eq " plan | apply "
}

@test "G24b: no infra ssh, N termina com código 2 dizendo infra access" {
  authorized "198.51.100.20/32"
  run "$REPO/infra" ssh dev app-1 <<<"N"
  [ "$status" -eq 2 ]
  [[ "$output" == *"rode 'infra access dev'"* ]]
  ! grep -q '^ssh ' "$CALLS"
}

@test "G24b: com s, aplica só o plano salvo com o IP /32" {
  authorized "198.51.100.20/32"
  echo '{"resource_changes":[
    {"address":"module.environment.module.security.aws_vpc_security_group_ingress_rule.bastion_ssh[\"198.51.100.20/32\"]","change":{"actions":["delete"]}},
    {"address":"module.environment.module.security.aws_vpc_security_group_ingress_rule.bastion_ssh[\"203.0.113.10/32\"]","change":{"actions":["create"]}},
    {"address":"module.environment.module.network.aws_vpc.this","change":{"actions":["no-op"]}}]}' >"$FIX/tf-plan.json"
  access <<<"s"
  [ "$status" -eq 0 ]
  terraform_calls | grep -q 'plan .*-var=admin_ssh_cidrs=\["203.0.113.10/32"\] .*-out='
  terraform_calls | grep -q "apply -input=false $REPO/.infra/access-dev.tfplan"
}

@test "G24b: plano com outra mudança além da regra do SSH é recusado e nada é aplicado" {
  authorized "198.51.100.20/32"
  echo '{"resource_changes":[
    {"address":"module.environment.module.security.aws_vpc_security_group_ingress_rule.bastion_ssh[\"203.0.113.10/32\"]","change":{"actions":["create"]}},
    {"address":"module.environment.module.compute.aws_instance.node[\"web-2\"]","change":{"actions":["create"]}}]}' >"$FIX/tf-plan.json"
  access <<<"s"
  [ "$status" -eq 2 ]
  [[ "$output" == *"há outras mudanças pendentes"*"aws_instance.node"* ]]
  [[ "$output" == *"Rode 'infra up dev'"* ]]
  ! terraform_calls | grep -q " apply "
}

# --- (c) lista no tfvars ------------------------------------------------------------

@test "G24c: admin_ssh_cidrs preenchida no tfvars: nada é alterado, só aviso" {
  echo 'admin_ssh_cidrs = ["198.51.100.0/24"]' >>"$REPO/envs/dev/terraform.tfvars"
  access </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"não cobre o seu IP atual (203.0.113.10)"* ]]
  ! terraform_calls | grep -Eq " plan | apply "
}

# --- (d) detecção e --ip --------------------------------------------------------------

@test "G24d: falha na detecção do IP diz como usar --ip" {
  export FAKE_IP=""
  access </dev/null
  [ "$status" -eq 2 ]
  [[ "$output" == *"Informe-o com --ip <ip>"* ]]
}

@test "G24d: --ip válido vira /32" {
  authorized "198.51.100.7/32"
  access --ip 198.51.100.7 </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"(198.51.100.7) já está autorizado"* ]]
  ! grep -q "^curl " "$CALLS"
}

@test "G24d: --ip 0.0.0.0/0 e faixas são recusados (T9)" {
  access --ip 0.0.0.0/0 </dev/null
  [ "$status" -eq 2 ]
  [[ "$output" == *"SSH aberto para o mundo é proibido"* ]]
  access --ip 203.0.113.0/24 </dev/null
  [ "$status" -eq 2 ]
}

@test "infra ssh conecta pelo bastion ao nó pedido com a chave do ambiente" {
  authorized "203.0.113.10/32"
  run "$REPO/infra" ssh dev app-1 </dev/null
  [ "$status" -eq 0 ]
  grep -q "^ssh -i $REPO/.keys/dev.pem .*ProxyCommand=ssh .*ubuntu@203.0.113.5 ubuntu@10.0.3.10" "$CALLS"
}
