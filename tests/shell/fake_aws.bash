# Ambiente simulado para os testes do infra: uma cópia do repositório numa
# pasta temporária e executáveis falsos de aws, terraform e hostname no PATH.
# Nenhuma chamada à AWS. Uso: load fake_aws (no setup do arquivo .bats).
#
# Controles (variáveis de ambiente e arquivos em $FIX):
#   AWS_STS=ok|fail           resposta do sts get-caller-identity
#   AWS_TOKEN=<texto>         token de sessão (vazio = sem token)
#   $FIX/buckets/<nome>       existe => head-bucket responde que o bucket existe
#   $FIX/s3/<bucket>/<chave>  conteúdo devolvido por aws s3 cp s3://bucket/chave -
#   $FIX/aws/<serviço>-<op>.json  resposta das consultas de sobras
#   TF_PLAN_RC=0|2            código do terraform plan -detailed-exitcode
#   TF_APPLY_RC=0|1           código do terraform apply
#   $FIX/tf-state-list        saída do terraform state list
#   $FIX/tf-remote.tfstate    saída do terraform state pull
# Registro das chamadas: $CALLS (uma linha por chamada: "aws ..." ou "terraform ...").

REPO_SRC="$BATS_TEST_DIRNAME/../.."

fake_setup() {
  REPO="$BATS_TEST_TMPDIR/repo"
  FIX="$BATS_TEST_TMPDIR/fix"
  BIN="$BATS_TEST_TMPDIR/bin"
  CALLS="$BATS_TEST_TMPDIR/calls"
  mkdir -p "$REPO/scripts/lib" "$REPO/bootstrap" "$REPO/envs/dev" "$REPO/envs/prod" \
    "$FIX/buckets" "$FIX/s3" "$FIX/aws" "$BIN"
  : >"$CALLS"
  cp "$REPO_SRC/infra" "$REPO/"
  cp "$REPO_SRC"/scripts/*.sh "$REPO/scripts/"
  cp "$REPO_SRC/scripts/lib/common.sh" "$REPO/scripts/lib/"
  cp "$REPO_SRC/bootstrap/terraform.tfvars" "$REPO/bootstrap/"
  cp "$REPO_SRC/envs/dev/terraform.tfvars" "$REPO/envs/dev/"
  cp "$REPO_SRC/envs/prod/terraform.tfvars" "$REPO/envs/prod/"

  export FIX CALLS
  export AWS_STS=ok AWS_TOKEN="token-de-teste" TF_PLAN_RC=0
  unset AWS_SESSION_TOKEN AWS_REGION AWS_DEFAULT_REGION

  fake_bin aws <<'EOF'
echo "aws $*" >>"$CALLS"
[[ "${1:-}" == --version ]] && { echo "aws-cli/2.37.12 Python/3.14 Linux/6.6 exe/x86_64"; exit 0; }
case "$1 $2" in
  "sts get-caller-identity")
    [[ "$AWS_STS" == ok ]] || { echo "An error occurred (ExpiredToken)" >&2; exit 255; }
    echo 000000000000 ;;
  "configure get")
    case "$3" in
      aws_session_token) [[ -n "$AWS_TOKEN" ]] && echo "$AWS_TOKEN" || exit 1 ;;
      region) echo us-east-1 ;;
    esac ;;
  "s3api head-bucket") [[ -e "$FIX/buckets/$4" ]] || exit 254 ;;
  "s3 cp")
    src="${3#s3://}"
    [[ -f "$FIX/s3/$src" ]] || exit 1
    cat "$FIX/s3/$src" ;;
  "ec2 describe-instances")
    if [[ "$*" == *"length("* ]]; then echo "${FAKE_RUNNING:-0}"; exit 0; fi
    cat "$FIX/aws/ec2-instances.json" 2>/dev/null || echo '{"Reservations":[]}' ;;
  "s3api list-buckets") cat "$FIX/aws/buckets.txt" 2>/dev/null || true ;;
  "ec2 describe-nat-gateways") cat "$FIX/aws/ec2-nat.json" 2>/dev/null || echo '{"NatGateways":[]}' ;;
  "ec2 describe-addresses") cat "$FIX/aws/ec2-eip.json" 2>/dev/null || echo '{"Addresses":[]}' ;;
  "elbv2 describe-load-balancers") cat "$FIX/aws/elb-lbs.json" 2>/dev/null || echo '{"LoadBalancers":[]}' ;;
  "elbv2 describe-tags") cat "$FIX/aws/elb-tags.json" 2>/dev/null || echo '{"TagDescriptions":[]}' ;;
  "rds describe-db-instances") cat "$FIX/aws/rds.json" 2>/dev/null || echo '{"DBInstances":[]}' ;;
  "ec2 describe-security-group-rules") cat "$FIX/aws/sg-rules.json" 2>/dev/null || echo '{"SecurityGroupRules":[]}' ;;
  "s3 ls")
    dir="$FIX/s3/${3#s3://}"
    [[ -d "$dir" ]] || exit 1
    for f in "$dir"*; do [[ -f "$f" ]] && echo "2026-10-12 00:00:00 10 $(basename "$f")"; done ;;
  *) exit 0 ;;
esac
EOF

  fake_bin terraform <<'EOF'
echo "terraform $*" >>"$CALLS"
args=" $* "
env=dev
[[ "$args" == *"/envs/prod "* ]] && env=prod
case "$args" in
  *" plan "*"-detailed-exitcode"*) exit "${TF_PLAN_RC:-0}" ;;
  *" plan "*"-out="*) exit "${TF_PLAN_RC:-0}" ;;
  *" apply "*) exit "${TF_APPLY_RC:-0}" ;;
  *" state list "*) cat "$FIX/tf-state-list" 2>/dev/null || true ;;
  *" state pull "*) cat "$FIX/tf-remote.tfstate" 2>/dev/null || true ;;
  *" show -json "*) cat "$FIX/tf-plan.json" 2>/dev/null || echo '{"resource_changes":[]}' ;;
  *" version "*) echo "Terraform v1.16.5" ;;
  *" output -json node_ips "*) printf '{"tem-na-festa-%s-app-1":"10.0.3.10","tem-na-festa-%s-web-1":"10.0.1.10"}\n' "$env" "$env" ;;
  *" output -json admin_ssh_cidrs "*) cat "$FIX/tf-admin-cidrs.json" 2>/dev/null || echo '[]' ;;
  *" output -raw bastion_public_ip "*) printf '203.0.113.5' ;;
  *" output -raw bastion_security_group_id "*) printf 'sg-bastion' ;;
  *" output -raw name_prefix "*) printf 'tem-na-festa-%s' "$env" ;;
  *" output -raw ssh_public_key "*) [[ -f "$FIX/no-state" ]] && exit 1; cat "$FIX/key.pub" ;;
  *" output -raw ssh_private_key "*) cat "$FIX/key" ;;
esac
exit 0
EOF

  fake_bin hostname <<'EOF'
echo maquina-teste
EOF

  # IP público detectado (checkip); FAKE_IP vazio simula falha.
  fake_bin curl <<'EOF'
echo "curl $*" >>"$CALLS"
[[ -n "${FAKE_IP-203.0.113.10}" ]] || exit 6
printf '%s\n' "${FAKE_IP-203.0.113.10}"
EOF

  # ssh-keygen -y -f <arq>: devolve a chave pública "derivada" do arquivo.
  fake_bin ssh-keygen <<'EOF'
f="${@: -1}"
sed -n 's/^PUB://p' "$f"
EOF

  fake_bin ssh <<'EOF'
echo "ssh $*" >>"$CALLS"
EOF

  # Par de chaves simulado: a "privada" é só um texto com a pública numa linha
  # PUB: (sem o cabeçalho de chave real, para a varredura de segredos do CI).
  printf 'ssh-ed25519 AAAAchave-atual\n' >"$FIX/key.pub"
  printf 'chave-simulada-de-teste\nPUB:ssh-ed25519 AAAAchave-atual\n' >"$FIX/key"

  export PATH="$BIN:$PATH"
}

# fake_bin <nome>: cria um executável falso com o corpo lido da entrada padrão.
fake_bin() {
  { printf '#!%s\n' "$(command -v bash)"; cat; } >"$BIN/$1"
  chmod +x "$BIN/$1"
}

# terraform_calls: chamadas registradas ao terraform.
terraform_calls() { grep '^terraform ' "$CALLS" || true; }

# token_hash: o mesmo resumo que o infra calcula para AWS_TOKEN.
token_hash() { printf '%s' "$AWS_TOKEN" | sha256sum | cut -c1-16; }

# session_json <primeira vez (s atrás)> [minutos informados] [informado (s atrás)]
session_json() {
  local now first rep_min="${2:-null}" rep_at="null"
  now="$(date +%s)"
  first=$((now - $1))
  [[ -n "${3:-}" ]] && rep_at=$((now - $3))
  mkdir -p "$REPO/.infra"
  printf '{"token_hash":"%s","first_seen":%s,"reported_minutes":%s,"reported_at":%s}\n' \
    "$(token_hash)" "$first" "$rep_min" "$rep_at" >"$REPO/.infra/session.json"
}

# env_ready <env>: status no bucket de artefatos de um ambiente pronto (04, seção 8).
env_ready() {
  local b="$FIX/s3/tnf-$1-artifacts-000000000000-us-east-1/status"
  mkdir -p "$b/nodes"
  local h
  for h in app-1 web-1; do
    echo '{"state":"joined","step":"fim"}' >"$b/nodes/tem-na-festa-$1-$h.json"
  done
  echo '{"state":"ready","step":"fim"}' >"$b/nodes/tem-na-festa-$1-bastion.json"
  echo '{"state":"ready","message":"todos os nós esperados estão Ready e rotulados"}' >"$b/converge.json"
}

STATE_BUCKET="tnf-tfstate-000000000000-us-east-1"
BRONZE_BUCKET="bucket-bronze-000000000000-us-east-1"
