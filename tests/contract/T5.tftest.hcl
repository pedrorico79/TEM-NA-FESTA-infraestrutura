# T5 (03, seção 6): manager_count = 2 é recusado; o número de managers deve ser ímpar (1, 3 ou 5).
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

run "T5_managers_par_recusado" {
  command = plan

  module {
    source = "../../modules/environment"
  }

  variables {
    manager_count  = 2
    app_node_count = 3
  }

  expect_failures = [var.manager_count]
}

run "T5_managers_cinco_aceito" {
  command = plan

  module {
    source = "../../modules/environment"
  }

  variables {
    manager_count    = 5
    app_node_count   = 5
    web_node_count   = 1
    service_replicas = { frontend = 1, backend = 1, messaging = 0 }
  }
}
