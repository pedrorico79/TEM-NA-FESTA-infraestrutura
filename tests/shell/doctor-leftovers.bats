#!/usr/bin/env bats
# G17 (08, seção 5.2): o infra doctor lista como sobras prováveis os recursos
# sem as etiquetas ManagedBy = terraform e Project = tem-na-festa, e não
# apaga nada. aws simulado (fake_aws.bash).

load fake_aws

setup() {
  fake_setup
}

OURS='[{"Key":"ManagedBy","Value":"terraform"},{"Key":"Project","Value":"tem-na-festa"},{"Key":"Name","Value":"tem-na-festa-dev-app-1"}]'

@test "G17: conta limpa não tem sobras" {
  run "$REPO/infra" doctor
  [[ "$output" == *"[ok]    nenhuma sobra da infraestrutura antiga"* ]]
}

@test "G17: lista EC2, NAT, Elastic IP, load balancer e RDS sem as etiquetas e ignora os desta versão" {
  cat >"$FIX/aws/ec2-instances.json" <<JSON
{"Reservations":[{"Instances":[
  {"InstanceId":"i-antiga","Tags":[{"Key":"Name","Value":"servidor-antigo"}]},
  {"InstanceId":"i-semtag"},
  {"InstanceId":"i-nossa","Tags":$OURS}
]}]}
JSON
  echo '{"NatGateways":[{"NatGatewayId":"nat-antiga","Tags":[]}]}' >"$FIX/aws/ec2-nat.json"
  echo '{"Addresses":[{"AllocationId":"eipalloc-antiga","PublicIp":"198.51.100.7"}]}' >"$FIX/aws/ec2-eip.json"
  echo '{"LoadBalancers":[{"LoadBalancerArn":"arn:aws:elasticloadbalancing:us-east-1:000000000000:loadbalancer/app/alb-antigo/abc"}]}' >"$FIX/aws/elb-lbs.json"
  echo '{"TagDescriptions":[{"ResourceArn":"arn:aws:elasticloadbalancing:us-east-1:000000000000:loadbalancer/app/alb-antigo/abc","Tags":[]}]}' >"$FIX/aws/elb-tags.json"
  echo '{"DBInstances":[{"DBInstanceIdentifier":"banco-antigo","DBInstanceClass":"db.t3.micro","TagList":[{"Key":"ManagedBy","Value":"terraform"}]}]}' >"$FIX/aws/rds.json"

  run "$REPO/infra" doctor
  [[ "$output" == *"sobra provável: ec2 i-antiga (servidor-antigo)"* ]]
  [[ "$output" == *"sobra provável: ec2 i-semtag (-)"* ]]
  [[ "$output" != *"i-nossa"* ]]
  [[ "$output" == *"sobra provável: nat nat-antiga"* ]]
  [[ "$output" == *"sobra provável: eip eipalloc-antiga (198.51.100.7)"* ]]
  [[ "$output" == *"sobra provável: alb alb-antigo"* ]]
  [[ "$output" == *"sobra provável: rds banco-antigo (db.t3.micro)"* ]]
  [[ "$output" == *"remova-os à mão no console da AWS antes da E3"* ]]
}

@test "G17: o doctor não apaga nada" {
  echo '{"Reservations":[{"Instances":[{"InstanceId":"i-antiga"}]}]}' >"$FIX/aws/ec2-instances.json"
  run "$REPO/infra" doctor
  ! grep -Eiq 'terminate|delete|release|remove|modify' "$CALLS"
}

@test "G17: sem credenciais válidas a procura de sobras é pulada" {
  export AWS_STS=fail
  run "$REPO/infra" doctor
  [[ "$output" == *"procura de sobras pulada"* ]]
  ! grep -q 'describe-instances' "$CALLS"
}

@test "H23: bucket de artefatos de ambiente fora do ar é apontado como sobra" {
  printf 'tnf-tfstate-000000000000-us-east-1\ttnf-dev-artifacts-000000000000-us-east-1\n' >"$FIX/aws/buckets.txt"
  run "$REPO/infra" doctor
  [[ "$output" == *"sobra provável: bucket de artefatos tnf-dev-artifacts-000000000000-us-east-1"* ]]
  [[ "$output" == *"aws s3 rb s3://tnf-dev-artifacts-000000000000-us-east-1 --force"* ]]
  ! grep -Eq 's3 rb|delete-bucket' "$CALLS"
}

@test "H23: bucket de artefatos de ambiente no ar não é sobra" {
  printf 'tnf-dev-artifacts-000000000000-us-east-1\n' >"$FIX/aws/buckets.txt"
  export FAKE_RUNNING=3
  run "$REPO/infra" doctor
  [[ "$output" != *"bucket de artefatos"* ]]
}
