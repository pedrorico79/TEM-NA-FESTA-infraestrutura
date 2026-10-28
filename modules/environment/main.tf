# Módulo de composição do ambiente (08, seção 3). Nesta etapa (E1) ele
# valida o contrato de 03 e calcula os valores derivados (03, seção 5); os
# módulos de rede, segurança, nós, banco, segredos, artefatos e ALB entram a
# partir da E3 (o ALB na E6), ligados aqui.

# --- AZs ------------------------------------------------------------------------
# Sem az_names, usa as primeiras AZs disponíveis (em ordem alfabética) que
# oferecem todos os tipos de instância escolhidos (03, seção 3.1). O ALB e o
# RDS exigem duas AZs, então as subnets públicas e de banco sempre usam duas,
# mesmo com az_count = 1 (02, subnets).

data "aws_availability_zones" "available" {
  count = var.az_names == null ? 1 : 0

  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_ec2_instance_type_offerings" "by_az" {
  count = var.az_names == null ? 1 : 0

  location_type = "availability-zone"

  filter {
    name   = "instance-type"
    values = local.instance_types
  }
}

locals {
  prefix = "${var.project_name}-${var.env}"

  instance_types = distinct(concat(
    [var.web_instance_type, var.app_instance_type],
    var.bastion_enabled ? [var.bastion_instance_type] : [],
  ))

  # Pares "AZ|tipo" oferecidos na região.
  offered = var.az_names != null ? [] : [
    for i, location in data.aws_ec2_instance_type_offerings.by_az[0].locations :
    "${location}|${data.aws_ec2_instance_type_offerings.by_az[0].instance_types[i]}"
  ]

  candidate_azs = var.az_names != null ? var.az_names : sort([
    for az in data.aws_availability_zones.available[0].names : az
    if alltrue([for t in local.instance_types : contains(local.offered, "${az}|${t}")])
  ])

  # Duas AZs: [AZ1, AZ2]. As az_count primeiras recebem nós web e app.
  az_list        = slice(local.candidate_azs, 0, min(2, length(local.candidate_azs)))
  active_az_list = slice(local.az_list, 0, min(var.az_count, length(local.az_list)))
}

# --- Subnets (03, seção 5) ---------------------------------------------------------
# cidrsubnet(vpc_cidr, 3, n): pública AZ1 = 0, web AZ1 = 1, web AZ2 = 2,
# app AZ1 = 3, app AZ2 = 4, db AZ1 = 5, db AZ2 = 6, pública AZ2 = 7.

locals {
  subnet_netnums = {
    public = [0, 7]
    web    = [1, 2]
    app    = [3, 4]
    db     = [5, 6]
  }

  subnet_cidrs = {
    for tier, netnums in local.subnet_netnums :
    tier => [for n in netnums : cidrsubnet(var.vpc_cidr, 3, n)]
  }
}

# --- Nós (03, seções 3.2 e 5) ------------------------------------------------------
# Rodízio: o nó de índice i (a partir de 0) fica na AZ i mod az_count e recebe
# o host 10 + i da subnet do seu grupo nessa AZ. As chaves (web-1, app-1...)
# são estáveis, para mudar a contagem não recriar nós existentes (08, 4.1).
# O final do hostname (-web-<n>, -app-<n>) é contrato com o converge.sh.

locals {
  groups = {
    web = var.web_node_count
    app = var.app_node_count
  }

  nodes = merge([
    for group, total in local.groups : {
      for i in range(total) : "${group}-${i + 1}" => {
        group       = group
        index       = i
        hostname    = "${local.prefix}-${group}-${i + 1}"
        az_index    = i % var.az_count
        az          = try(local.az_list[i % var.az_count], null)
        subnet_cidr = local.subnet_cidrs[group][i % var.az_count]
        private_ip  = cidrhost(local.subnet_cidrs[group][i % var.az_count], 10 + i)
        manager     = group == "app" && i < var.manager_count
      }
    }
  ]...)

  bastion = var.bastion_enabled ? {
    hostname    = "${local.prefix}-bastion"
    az          = try(local.az_list[0], null)
    subnet_cidr = local.subnet_cidrs.public[0]
  } : null

  instance_count = var.web_node_count + var.app_node_count + (var.bastion_enabled ? 1 : 0)

  # Hostnames dos nós do Swarm (sem o bastion), web e depois app.
  expected_nodes = concat(
    [for i in range(var.web_node_count) : "${local.prefix}-web-${i + 1}"],
    [for i in range(var.app_node_count) : "${local.prefix}-app-${i + 1}"],
  )

  manager_nodes = [for i in range(var.manager_count) : "${local.prefix}-app-${i + 1}"]
}

# --- stack.env (03, seção 5; 06, seção 4) ----------------------------------------
# Valores sem segredos lidos pelo líder do Swarm. DB_ENDPOINT vem do módulo
# database (E4b). Com a mensageria desligada, IMAGE_MESSAGING e
# MESSAGING_PORT são gravados, mas ignorados. DB_SCHEMA_* ficam em branco
# quando o banco nasce de um snapshot.

locals {
  db_app_username       = "tnf_app"         # nome fixo do usuário da aplicação (05, A1)
  db_messaging_username = "tnf_notificacao" # usuário do microsserviço no schema dele (E8)

  restoring_from_snapshot = var.db_snapshot_identifier != null

  stack_env = {
    IMAGE_FRONTEND     = "${var.dockerhub_namespace}/tnf-frontend:${var.image_tags.frontend}"
    IMAGE_BACKEND      = "${var.dockerhub_namespace}/tnf-backend:${var.image_tags.backend}"
    IMAGE_MESSAGING    = "${var.dockerhub_namespace}/tnf-messaging:${var.image_tags.messaging}"
    REPLICAS_FRONTEND  = tostring(var.service_replicas.frontend)
    REPLICAS_BACKEND   = tostring(var.service_replicas.backend)
    REPLICAS_MESSAGING = tostring(var.service_replicas.messaging)
    DB_ENDPOINT        = module.database.endpoint
    DB_NAME            = var.db_name
    DB_USER            = local.db_app_username
    MESSAGING_PORT     = var.messaging_port == null ? "" : tostring(var.messaging_port)
    EXPECTED_NODES     = join(",", local.expected_nodes)
    MANAGER_COUNT      = tostring(var.manager_count)
    DB_SCHEMA_REPO_URL = local.restoring_from_snapshot ? "" : var.db_schema_repo_url
    DB_SCHEMA_REF      = local.restoring_from_snapshot ? "" : var.db_schema_ref
    DB_SCHEMA_PATH     = local.restoring_from_snapshot ? "" : var.db_schema_path
    # Banco do microsserviço (E8): sempre preenchidas com a mensageria ligada,
    # porque um snapshot de antes da E8 não tem esse schema; o db-init só roda
    # o script se o schema estiver vazio.
    MESSAGING_DB_NAME            = var.messaging_db_name
    MESSAGING_DB_USER            = local.db_messaging_username
    MESSAGING_DB_SCHEMA_REPO_URL = var.messaging_db_schema_repo_url
    MESSAGING_DB_SCHEMA_REF      = var.messaging_db_schema_ref
    MESSAGING_DB_SCHEMA_PATH     = var.messaging_db_schema_path
  }

  ssh_private_key_path = coalesce(var.ssh_private_key_path, abspath("${path.module}/../../.keys/${var.env}.pem"))
}

# --- Recursos do ambiente (E3 e E4a) ------------------------------------------------
# Nomes por 08, seção 4.2. O bucket de artefatos é criado pelo infra up com o
# AWS CLI antes do apply (08, H23); aqui só o nome.

data "aws_caller_identity" "current" {}

locals {
  account_id         = data.aws_caller_identity.current.account_id
  artifacts_bucket   = "tnf-${var.env}-artifacts-${local.account_id}-${var.region}"
  bronze_bucket_name = coalesce(var.bronze_bucket_name, "bucket-bronze-${local.account_id}-${var.bronze_bucket_region}")
  repo_root          = abspath("${path.module}/../..")
}

module "network" {
  source = "../network"

  name_prefix = local.prefix
  vpc_cidr    = var.vpc_cidr
  az_names    = local.az_list
  az_count    = var.az_count
  nat_mode    = var.nat_mode
}

module "security" {
  source = "../security"

  name_prefix     = local.prefix
  vpc_id          = module.network.vpc_id
  admin_ssh_cidrs = var.admin_ssh_cidrs
}

module "secrets" {
  source = "../secrets"

  env               = var.env
  messaging_secrets = var.messaging_secrets
}

module "artifacts" {
  source = "../artifacts"

  bucket_name = local.artifacts_bucket
  stack_env   = local.stack_env
  node_dir    = "${local.repo_root}/node"
  stacks_dir  = "${local.repo_root}/stacks"
}

module "database" {
  source = "../database"

  name_prefix          = local.prefix
  subnet_ids           = module.network.subnet_ids["db"]
  security_group_id    = module.security.security_group_ids["rds"]
  engine_version       = var.db_engine_version
  instance_class       = var.db_instance_class
  allocated_storage_gb = var.db_allocated_storage_gb
  multi_az             = var.db_multi_az
  db_name              = var.db_name
  master_username      = var.db_master_username
  master_password      = module.secrets.db_admin_password
  snapshot_identifier  = var.db_snapshot_identifier
}

module "compute" {
  source = "../compute"

  env                   = var.env
  name_prefix           = local.prefix
  region                = var.region
  nodes                 = { for k, n in local.nodes : k => { group = n.group, index = n.index, hostname = n.hostname, az_index = n.az_index, private_ip = n.private_ip, manager = n.manager } }
  subnet_ids            = module.network.subnet_ids
  security_group_ids    = module.security.security_group_ids
  web_instance_type     = var.web_instance_type
  app_instance_type     = var.app_instance_type
  bastion_instance_type = var.bastion_instance_type
  bastion_enabled       = var.bastion_enabled
  root_volume_size_gb   = var.root_volume_size_gb
  ami_id                = var.ami_id
  artifacts_bucket      = module.artifacts.bucket_name
  bronze_bucket         = local.bronze_bucket_name
  bronze_region         = var.bronze_bucket_region
  ssh_private_key_path  = local.ssh_private_key_path
  node_dir              = "${local.repo_root}/node"
  node_objects          = module.artifacts.node_objects

  # EC2 depois das rotas da NAT (04, seção 4); os scripts no bucket chegam por
  # node_objects. O RDS cria em paralelo: só o READY espera por ele.
  depends_on = [module.network, module.secrets]
}

module "alb" {
  source = "../alb"

  name_prefix       = local.prefix
  vpc_id            = module.network.vpc_id
  subnet_ids        = module.network.subnet_ids["public"]
  security_group_id = module.security.security_group_ids["alb"]
  web_instance_ids  = { for k, n in module.compute.nodes : k => n.id if startswith(k, "web-") }
}
