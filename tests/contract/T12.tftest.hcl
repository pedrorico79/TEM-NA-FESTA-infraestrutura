# T12 (03, seção 6): com os padrões de dev (mensageria desligada) e as variáveis sem padrão preenchidas, o plan é válido com 3 instâncias; com db_snapshot_identifier e db_schema_* em branco também, e o stack.env traz DB_SCHEMA_* em branco. Confere também os valores derivados (03, seção 5) e a topologia de prod.
# Provedor AWS simulado; nenhuma chamada à AWS (07, seção 6).

mock_provider "aws" {
  source = "./mocks"
}

variables {
  env                 = "dev"
  dockerhub_namespace = "exemplo"
  db_schema_repo_url  = "https://example.invalid/schema.git"
  db_schema_ref       = "v0.0.0-teste"
  db_schema_path      = "schema/teste.sql"
}

run "T12_padroes_de_dev" {
  command = plan

  module {
    source = "../../modules/environment"
  }

  assert {
    condition     = output.instance_count == 3
    error_message = "dev deve ter 3 instâncias (1 web, 1 app, bastion)"
  }

  assert {
    condition     = output.stack_env.DB_SCHEMA_REPO_URL == "https://example.invalid/schema.git"
    error_message = "DB_SCHEMA_REPO_URL deve vir de db_schema_repo_url"
  }

  assert {
    condition     = output.stack_env.DB_SCHEMA_REF == "v0.0.0-teste"
    error_message = "DB_SCHEMA_REF deve vir de db_schema_ref"
  }

  assert {
    condition     = output.stack_env.DB_SCHEMA_PATH == "schema/teste.sql"
    error_message = "DB_SCHEMA_PATH deve vir de db_schema_path"
  }

  assert {
    condition     = output.stack_env.EXPECTED_NODES == "tem-na-festa-dev-web-1,tem-na-festa-dev-app-1"
    error_message = "EXPECTED_NODES deve listar os nós web e app, sem o bastion"
  }

  assert {
    condition     = output.stack_env.MANAGER_COUNT == "1"
    error_message = "MANAGER_COUNT deve ser 1 em dev"
  }

  assert {
    condition     = output.stack_env.REPLICAS_MESSAGING == "0"
    error_message = "a mensageria deve estar desligada"
  }

  assert {
    condition     = output.stack_env.MESSAGING_PORT == ""
    error_message = "MESSAGING_PORT deve ficar vazio com a mensageria desligada"
  }

  assert {
    condition     = output.stack_env.IMAGE_BACKEND == "exemplo/tnf-backend:dev"
    error_message = "IMAGE_BACKEND deve ser <namespace>/tnf-backend:<tag>"
  }

  assert {
    condition     = output.stack_env.DB_NAME == "tem_na_festa" && output.stack_env.DB_USER == "tnf_app"
    error_message = "DB_NAME e DB_USER devem seguir 03 e 05"
  }

  assert {
    condition     = output.name_prefix == "tem-na-festa-dev"
    error_message = "o prefixo deve ser <project_name>-<env>"
  }

  assert {
    condition     = output.az_names == tolist(["us-east-1a", "us-east-1b"])
    error_message = "as duas primeiras AZs que oferecem os tipos devem ser usadas"
  }

  assert {
    condition     = output.subnet_cidrs.public == ["10.0.0.0/24", "10.0.7.0/24"]
    error_message = "subnets públicas: netnum 0 e 7"
  }

  assert {
    condition     = output.subnet_cidrs.web == ["10.0.1.0/24", "10.0.2.0/24"]
    error_message = "subnets web: netnum 1 e 2"
  }

  assert {
    condition     = output.subnet_cidrs.app == ["10.0.3.0/24", "10.0.4.0/24"]
    error_message = "subnets app: netnum 3 e 4"
  }

  assert {
    condition     = output.subnet_cidrs.db == ["10.0.5.0/24", "10.0.6.0/24"]
    error_message = "subnets db: netnum 5 e 6"
  }

  assert {
    condition     = output.nodes["app-1"].private_ip == "10.0.3.10" && output.nodes["app-1"].manager
    error_message = "app-1 deve ter o host 10 da subnet app da AZ1 e ser manager"
  }

  assert {
    condition     = output.nodes["web-1"].private_ip == "10.0.1.10" && !output.nodes["web-1"].manager
    error_message = "web-1 deve ter o host 10 da subnet web da AZ1"
  }

  assert {
    condition     = output.bastion.hostname == "tem-na-festa-dev-bastion" && output.bastion.subnet_cidr == "10.0.0.0/24"
    error_message = "o bastion fica na subnet pública da AZ1"
  }
}

run "T12_snapshot_com_db_schema_em_branco" {
  command = plan

  module {
    source = "../../modules/environment"
  }

  variables {
    db_snapshot_identifier = "tem-na-festa-dev-final-0a1b2c3d"
    db_schema_repo_url     = ""
    db_schema_ref          = ""
    db_schema_path         = ""
  }

  assert {
    condition     = output.instance_count == 3
    error_message = "dev deve ter 3 instâncias também ao restaurar de snapshot"
  }

  assert {
    condition     = output.stack_env.DB_SCHEMA_REPO_URL == "" && output.stack_env.DB_SCHEMA_REF == "" && output.stack_env.DB_SCHEMA_PATH == ""
    error_message = "DB_SCHEMA_* devem ficar em branco quando o banco nasce de um snapshot"
  }
}

run "T12_topologia_de_prod" {
  command = plan

  module {
    source = "../../modules/environment"
  }

  variables {
    env               = "prod"
    az_count          = 2
    nat_mode          = "per_az"
    web_node_count    = 2
    app_node_count    = 3
    manager_count     = 3
    service_replicas  = { frontend = 2, backend = 2, messaging = 0 }
    image_tags        = { frontend = "prod", backend = "prod", messaging = "prod" }
    db_instance_class = "db.t3.small"
  }

  assert {
    condition     = output.instance_count == 6
    error_message = "a topologia de prod deve ter 6 instâncias"
  }

  assert {
    condition     = output.active_az_names == tolist(["us-east-1a", "us-east-1b"])
    error_message = "prod usa as duas AZs para os nós"
  }

  assert {
    condition     = output.manager_nodes == ["tem-na-festa-prod-app-1", "tem-na-festa-prod-app-2", "tem-na-festa-prod-app-3"]
    error_message = "os managers são os 3 primeiros nós app"
  }

  assert {
    condition     = output.nodes["web-2"].az == "us-east-1b" && output.nodes["web-2"].private_ip == "10.0.2.11"
    error_message = "web-2 fica na AZ2 com o host 11 da subnet web da AZ2"
  }

  assert {
    condition     = output.nodes["app-2"].az == "us-east-1b" && output.nodes["app-2"].private_ip == "10.0.4.11"
    error_message = "app-2 fica na AZ2 com o host 11 da subnet app da AZ2"
  }

  assert {
    condition     = output.nodes["app-3"].az == "us-east-1a" && output.nodes["app-3"].private_ip == "10.0.3.12"
    error_message = "app-3 volta à AZ1 (rodízio) com o host 12"
  }

  assert {
    condition     = output.stack_env.EXPECTED_NODES == "tem-na-festa-prod-web-1,tem-na-festa-prod-web-2,tem-na-festa-prod-app-1,tem-na-festa-prod-app-2,tem-na-festa-prod-app-3"
    error_message = "EXPECTED_NODES de prod"
  }

  assert {
    condition     = output.stack_env.MANAGER_COUNT == "3" && output.stack_env.REPLICAS_BACKEND == "2"
    error_message = "MANAGER_COUNT e réplicas de prod"
  }
}
