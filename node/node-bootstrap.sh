#!/usr/bin/env bash
# Preparação de cada nó (04, seções 5 e 6). Roda como root, chamado pelo
# user_data, e é o mesmo nos três papéis:
#   web e app: Fluent Bit, jq, Docker e a entrada no Swarm (app: também o
#              cliente MySQL e o tnf-db-shell; managers: a convergência);
#   bastion:   só AWS CLI, jq e Fluent Bit, sem Docker nem Swarm.
# O andamento vai para status/nodes/<hostname>.json no bucket de artefatos.
# Idempotente: rodar de novo não refaz o que já está pronto.
set -euo pipefail

# shellcheck source=/dev/null
source /etc/tnf-node.env
: "${TNF_ENV:?}" "${TNF_ROLE:?}" "${TNF_HOSTNAME:?}" "${TNF_REGION:?}" "${TNF_ARTIFACTS_BUCKET:?}" "${TNF_LEADER_IP:?}" "${TNF_MANAGER:?}"

# Versões fixadas (04, seção 5): série maior do repositório oficial.
DOCKER_VERSION="5:28.*"
FLUENT_BIT_VERSION="4.*"

S3="s3://$TNF_ARTIFACTS_BUCKET"
LOG=/var/log/tnf-bootstrap.log
STEP="inicio"
exec >>"$LOG" 2>&1

log() { printf '%s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$STEP" "$*"; }

# status <estado> [mensagem]: grava status/nodes/<hostname>.json (04, D6).
status() {
  jq -n --arg host "$TNF_HOSTNAME" --arg role "$TNF_ROLE" --arg state "$1" \
    --arg step "$STEP" --arg message "${2:-}" --arg time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{host: $host, role: $role, state: $state, step: $step, message: $message, time: $time}' |
    aws s3 cp - "$S3/status/nodes/$TNF_HOSTNAME.json" --region "$TNF_REGION" --only-show-errors || true
}

fail() {
  log "falhou: $*"
  status failed "$*  (detalhes em $LOG)"
  exit 1
}
trap 'fail "erro inesperado na etapa $STEP (linha $LINENO)"' ERR

# retry <tentativas> <comando...>: repete com espera crescente (04, seção 10).
retry() {
  local tries="$1" n=1
  shift
  until "$@"; do
    if ((n >= tries)); then return 1; fi
    sleep $((n * 10))
    n=$((n + 1))
  done
}

# imds <caminho>: lê o serviço de metadados com o token do IMDSv2 (02, A14).
imds() {
  local token
  token="$(curl -fsS -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')"
  curl -fsS -H "X-aws-ec2-metadata-token: $token" "http://169.254.169.254/latest/meta-data/$1"
}

apt_install() {
  DEBIAN_FRONTEND=noninteractive retry 5 apt-get install -y -q "$@"
}

# --- 1. pacotes --------------------------------------------------------------------

install_base() {
  STEP="pacotes"
  status installing "instalando pacotes"
  retry 5 apt-get update -q
  apt_install jq curl ca-certificates gnupg
}

install_fluent_bit() {
  STEP="fluent-bit"
  if ! [[ -f /usr/share/keyrings/fluentbit-keyring.gpg ]]; then
    retry 5 curl -fsSL https://packages.fluentbit.io/fluentbit.key -o /tmp/fluentbit.key
    gpg --dearmor -o /usr/share/keyrings/fluentbit-keyring.gpg /tmp/fluentbit.key
    echo "deb [signed-by=/usr/share/keyrings/fluentbit-keyring.gpg] https://packages.fluentbit.io/ubuntu/noble noble main" >/etc/apt/sources.list.d/fluent-bit.list
    retry 5 apt-get update -q
  fi
  apt_install "fluent-bit=$FLUENT_BIT_VERSION"
}

install_docker() {
  STEP="docker"
  if ! [[ -f /etc/apt/keyrings/docker.asc ]]; then
    install -m 0755 -d /etc/apt/keyrings
    retry 5 curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" >/etc/apt/sources.list.d/docker.list
    retry 5 apt-get update -q
  fi
  apt_install "docker-ce=$DOCKER_VERSION" "docker-ce-cli=$DOCKER_VERSION" containerd.io

  # Rotação dos logs e rótulos do serviço e da stack nos logs (04, seção 5, passo 2).
  mkdir -p /etc/docker
  cat >/etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3",
    "labels": "com.docker.swarm.service.name,com.docker.stack.namespace"
  }
}
EOF
  systemctl enable docker
  systemctl restart docker
}

install_mysql_client() {
  STEP="mysql-client"
  apt_install mysql-client
  retry 5 aws s3 cp "$S3/node/tnf-db-shell.sh" /usr/local/bin/tnf-db-shell --region "$TNF_REGION" --only-show-errors
  chmod 755 /usr/local/bin/tnf-db-shell
}

# --- 3. Fluent Bit (02, seção 7.1) ---------------------------------------------------

configure_fluent_bit() {
  STEP="fluent-bit-config"
  if ! [[ -f /var/log/auth.log ]]; then
    apt_install rsyslog
    systemctl enable --now rsyslog
  fi
  mkdir -p /var/lib/fluent-bit/storage /var/lib/fluent-bit/s3
  retry 5 aws s3 cp "$S3/node/fluent-bit/$TNF_HOSTNAME.conf" /etc/fluent-bit/fluent-bit.conf --region "$TNF_REGION" --only-show-errors
  retry 5 aws s3 cp "$S3/node/fluent-bit/parsers.conf" /etc/fluent-bit/tnf-parsers.conf --region "$TNF_REGION" --only-show-errors
  systemctl enable fluent-bit
  systemctl restart fluent-bit
}

# --- 4. Swarm (04, seção 6) -----------------------------------------------------------

swarm_active() {
  [[ "$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null)" == active ]]
}

join_swarm() {
  STEP="swarm"
  if swarm_active; then
    log "já participa de um Swarm; nada a refazer"
    return 0
  fi
  status installing "entrando no Swarm"
  local my_ip
  my_ip="$(imds local-ipv4)"

  if [[ "$TNF_HOSTNAME" == *-app-1 ]] && ! aws s3api head-object --bucket "$TNF_ARTIFACTS_BUCKET" --key swarm/join.json --region "$TNF_REGION" >/dev/null 2>&1; then
    log "iniciando o Swarm como líder em $my_ip"
    docker swarm init --advertise-addr "$my_ip" >/dev/null
    jq -n --arg ip "$my_ip" \
      --arg manager "$(docker swarm join-token -q manager)" \
      --arg worker "$(docker swarm join-token -q worker)" \
      '{leader_ip: $ip, manager_token: $manager, worker_token: $worker}' |
      aws s3 cp - "$S3/swarm/join.json" --region "$TNF_REGION" --only-show-errors
    return 0
  fi

  # Demais nós (ou o app-1 recriado): esperam o join.json, a cada 10 s, até 10 min.
  local join="" waited=0
  until join="$(aws s3 cp "$S3/swarm/join.json" - --region "$TNF_REGION" 2>/dev/null)"; do
    if ((waited >= 600)); then fail "o join.json não apareceu em 10 minutos; o líder ($TNF_LEADER_IP) não iniciou o Swarm"; fi
    sleep 10
    waited=$((waited + 10))
  done
  local token leader
  leader="$(jq -r .leader_ip <<<"$join")"
  if [[ "$TNF_MANAGER" == true ]]; then
    token="$(jq -r .manager_token <<<"$join")"
  else
    token="$(jq -r .worker_token <<<"$join")"
  fi
  retry 30 docker swarm join --advertise-addr "$my_ip" --token "$token" "$leader:2377" >/dev/null ||
    fail "não foi possível entrar no Swarm do líder $leader em 10 minutos"
}

install_converge() {
  STEP="convergencia"
  retry 5 aws s3 cp "$S3/node/converge.sh" /usr/local/sbin/tnf-converge --region "$TNF_REGION" --only-show-errors
  chmod 755 /usr/local/sbin/tnf-converge
  retry 5 aws s3 cp "$S3/node/db-init.sh" /usr/local/sbin/tnf-db-init --region "$TNF_REGION" --only-show-errors
  chmod 755 /usr/local/sbin/tnf-db-init
  retry 5 aws s3 cp "$S3/node/systemd/tnf-converge.service" /etc/systemd/system/tnf-converge.service --region "$TNF_REGION" --only-show-errors
  retry 5 aws s3 cp "$S3/node/systemd/tnf-converge.timer" /etc/systemd/system/tnf-converge.timer --region "$TNF_REGION" --only-show-errors
  systemctl daemon-reload
  systemctl enable --now tnf-converge.timer
}

# --- principal ---------------------------------------------------------------------

main() {
  log "início do bootstrap: $TNF_HOSTNAME ($TNF_ROLE, $TNF_ENV)"
  install_base
  install_fluent_bit
  case "$TNF_ROLE" in
    web | app)
      install_docker
      [[ "$TNF_ROLE" == app ]] && install_mysql_client
      configure_fluent_bit
      join_swarm
      [[ "$TNF_MANAGER" == true ]] && install_converge
      STEP="fim"
      status joined "no Swarm"
      ;;
    bastion)
      configure_fluent_bit
      STEP="fim"
      status ready "bastion pronto"
      ;;
    *)
      fail "papel desconhecido: $TNF_ROLE"
      ;;
  esac
  log "bootstrap concluído"
}

main "$@"
