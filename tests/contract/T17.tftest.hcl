# T17 (03, seção 6): frontend ou backend com 0 réplicas e mensageria com 2 réplicas são recusados; só a mensageria pode ficar em 0, e só com 0 ou 1. Também verifica R15 (06).
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

run "T17_frontend_zero_recusado" {
  command = plan

  module {
    source = "../../modules/environment"
  }

  variables {
    service_replicas = { frontend = 0, backend = 1, messaging = 0 }
  }

  expect_failures = [var.service_replicas]
}

run "T17_backend_zero_recusado" {
  command = plan

  module {
    source = "../../modules/environment"
  }

  variables {
    service_replicas = { frontend = 1, backend = 0, messaging = 0 }
  }

  expect_failures = [var.service_replicas]
}

run "T17_mensageria_duas_replicas_recusada" {
  command = plan

  module {
    source = "../../modules/environment"
  }

  variables {
    service_replicas = { frontend = 1, backend = 1, messaging = 2 }
    app_node_count   = 3
    messaging_port   = 8090
  }

  expect_failures = [var.service_replicas]
}
