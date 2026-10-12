#!/usr/bin/env bats
# G23 (08, seção 5.5; 05, B2): escolha, listagem, criação e poda dos snapshots
# do banco, com aws e terraform simulados.

load fake_aws

setup() {
  fake_setup
  touch "$FIX/buckets/$STATE_BUCKET"
  session_json 0
  env_ready dev
  export TNF_WAIT_INTERVAL=0 TNF_WAIT_TIMEOUT=0
  cat >"$FIX/aws/rds-snapshots.json" <<'JSON'
{"DBSnapshots":[
  {"DBSnapshotIdentifier":"tem-na-festa-dev-final-aaaa0001","SnapshotCreateTime":"2026-10-01T10:00:00Z","Status":"available","AllocatedStorage":20},
  {"DBSnapshotIdentifier":"tem-na-festa-dev-final-aaaa0002","SnapshotCreateTime":"2026-10-05T10:00:00Z","Status":"available","AllocatedStorage":20},
  {"DBSnapshotIdentifier":"tem-na-festa-dev-final-aaaa0003","SnapshotCreateTime":"2026-10-07T10:00:00Z","Status":"available","AllocatedStorage":20},
  {"DBSnapshotIdentifier":"tem-na-festa-dev-final-aaaa0004","SnapshotCreateTime":"2026-10-09T10:00:00Z","Status":"available","AllocatedStorage":20},
  {"DBSnapshotIdentifier":"tem-na-festa-dev-manual-20261010-120000","SnapshotCreateTime":"2026-10-10T12:00:00Z","Status":"available","AllocatedStorage":20},
  {"DBSnapshotIdentifier":"tem-na-festa-dev-manual-20261002-120000","SnapshotCreateTime":"2026-10-02T12:00:00Z","Status":"available","AllocatedStorage":20},
  {"DBSnapshotIdentifier":"tem-na-festa-dev-manual-20261003-120000","SnapshotCreateTime":"2026-10-03T12:00:00Z","Status":"available","AllocatedStorage":20},
  {"DBSnapshotIdentifier":"tem-na-festa-dev-manual-20261004-120000","SnapshotCreateTime":"2026-10-04T12:00:00Z","Status":"available","AllocatedStorage":20},
  {"DBSnapshotIdentifier":"tem-na-festa-prod-final-bbbb0001","SnapshotCreateTime":"2026-10-11T10:00:00Z","Status":"available","AllocatedStorage":20},
  {"DBSnapshotIdentifier":"outro-snapshot-qualquer","SnapshotCreateTime":"2026-10-11T11:00:00Z","Status":"available","AllocatedStorage":20}
]}
JSON
}

up() { run "$REPO/infra" up dev --yes "$@" </dev/null; }

@test "G23: ambiente novo sem opções escolhe o final mais recente e ignora os manuais" {
  up
  [ "$status" -eq 0 ]
  terraform_calls | grep -q 'apply .*-var=db_snapshot_identifier=tem-na-festa-dev-final-aaaa0004'
}

@test "G23: --snapshot com um manual do ambiente usa esse" {
  up --snapshot tem-na-festa-dev-manual-20261010-120000
  [ "$status" -eq 0 ]
  terraform_calls | grep -q 'apply .*-var=db_snapshot_identifier=tem-na-festa-dev-manual-20261010-120000'
}

@test "G23: --snapshot inexistente é recusado com código 2 antes do apply" {
  up --snapshot tem-na-festa-dev-manual-20991231-000000
  [ "$status" -eq 2 ]
  [[ "$output" == *"não existe ou não está disponível"* ]]
  ! terraform_calls | grep -q ' apply '
}

@test "G23: --snapshot de outro ambiente é recusado com código 2 antes do apply" {
  up --snapshot tem-na-festa-prod-final-bbbb0001
  [ "$status" -eq 2 ]
  [[ "$output" == *"não é do ambiente dev"* ]]
  ! terraform_calls | grep -q ' apply '
}

@test "G23: com o ambiente no ar (RDS no state), --snapshot é recusado e sem opções nada é escolhido" {
  echo "module.environment.module.database.aws_db_instance.this" >"$FIX/tf-state-list"
  up --snapshot tem-na-festa-dev-final-aaaa0001
  [ "$status" -eq 2 ]
  [[ "$output" == *"já está no ar"* ]]
  ! terraform_calls | grep -q ' apply '
  up
  [ "$status" -eq 0 ]
  ! terraform_calls | grep -q 'db_snapshot_identifier'
}

@test "G23: sem nenhum snapshot final, avisa que o banco nasce vazio" {
  echo '{"DBSnapshots":[]}' >"$FIX/aws/rds-snapshots.json"
  up
  [ "$status" -eq 0 ]
  [[ "$output" == *"o banco nascerá vazio"* ]]
  ! terraform_calls | grep -q 'db_snapshot_identifier'
}

@test "G23: infra snapshots lista só os do ambiente, com o tipo" {
  run "$REPO/infra" snapshots dev
  [ "$status" -eq 0 ]
  [[ "$output" == *"tem-na-festa-dev-final-aaaa0004"*"final"* ]]
  [[ "$output" == *"tem-na-festa-dev-manual-20261010-120000"*"manual"* ]]
  [[ "$output" != *"prod"* ]]
  [[ "$output" != *"outro-snapshot"* ]]
}

@test "G23: a poda do down mantém 3 de cada tipo e não toca nos de outro ambiente" {
  run "$REPO/infra" down dev --yes </dev/null
  [ "$status" -eq 0 ]
  grep -q 'delete-db-snapshot .*tem-na-festa-dev-final-aaaa0001' "$CALLS"
  grep -q 'delete-db-snapshot .*tem-na-festa-dev-manual-20261002-120000' "$CALLS"
  [ "$(grep -c 'delete-db-snapshot' "$CALLS")" -eq 2 ]
  ! grep -q 'delete-db-snapshot .*prod' "$CALLS"
  ! grep -q 'delete-db-snapshot .*outro-snapshot' "$CALLS"
}

@test "infra snapshot cria o manual com o nome <prefixo>-manual-<data UTC>" {
  echo "module.environment.module.database.aws_db_instance.this" >"$FIX/tf-state-list"
  run "$REPO/infra" snapshot dev </dev/null
  [ "$status" -eq 0 ]
  grep -Eq 'create-db-snapshot .*--db-instance-identifier tem-na-festa-dev-db --db-snapshot-identifier tem-na-festa-dev-manual-[0-9]{8}-[0-9]{6}' "$CALLS"
}

@test "infra snapshot com o ambiente fora do ar é recusado" {
  run "$REPO/infra" snapshot dev </dev/null
  [ "$status" -eq 2 ]
  [[ "$output" == *"não está no ar"* ]]
}
