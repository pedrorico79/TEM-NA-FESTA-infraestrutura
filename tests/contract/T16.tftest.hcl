# T16 (03, seção 6): service_replicas.messaging = 1 sem messaging_port é recusado.
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

run "T16_mensageria_sem_porta_recusada" {
  command = plan

  module {
    source = "../../modules/environment"
  }

  variables {
    service_replicas             = { frontend = 1, backend = 1, messaging = 1 }
    messaging_db_schema_repo_url = "https://example.invalid/microsservico.git"
    messaging_db_schema_ref      = "v0.0.0-teste"
    messaging_db_schema_path     = "schema/notificacao.sql"
    messaging_secrets            = { whapi_token = "token-de-teste" }
  }

  expect_failures = [var.messaging_port]
}

run "T16_mensageria_com_porta_aceita" {
  command = plan

  module {
    source = "../../modules/environment"
  }

  variables {
    service_replicas             = { frontend = 1, backend = 1, messaging = 1 }
    messaging_port               = 8090
    messaging_db_schema_repo_url = "https://example.invalid/microsservico.git"
    messaging_db_schema_ref      = "v0.0.0-teste"
    messaging_db_schema_path     = "schema/notificacao.sql"
    messaging_secrets            = { whapi_token = "token-de-teste" }
  }

  assert {
    condition     = output.stack_env.MESSAGING_PORT == "8090" && output.stack_env.REPLICAS_MESSAGING == "1"
    error_message = "com a mensageria ligada, o stack.env leva a porta e 1 réplica"
  }
}

# E8: com a mensageria ligada, o banco do microsserviço e o token da Whapi
# também são exigidos (Q8 cobre o lado do secrets.env no infra).
run "T16_mensageria_sem_banco_nem_token_recusada" {
  command = plan

  module {
    source = "../../modules/environment"
  }

  variables {
    service_replicas = { frontend = 1, backend = 1, messaging = 1 }
    messaging_port   = 8090
  }

  expect_failures = [
    var.messaging_db_schema_repo_url,
    var.messaging_db_schema_ref,
    var.messaging_db_schema_path,
    var.messaging_secrets,
  ]
}
