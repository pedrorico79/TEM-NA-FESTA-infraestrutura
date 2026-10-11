# T4 (03, seção 6): manager_count = 3 com app_node_count = 2 é recusado (managers não podem exceder os nós app). Também verifica S7 (04).
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

run "T4_managers_maior_que_nos_app_recusado" {
  command = plan

  module {
    source = "../../modules/environment"
  }

  variables {
    manager_count  = 3
    app_node_count = 2
  }

  expect_failures = [var.manager_count]
}

run "T4_managers_igual_aos_nos_app_aceito" {
  command = plan

  module {
    source = "../../modules/environment"
  }

  variables {
    manager_count  = 3
    app_node_count = 3
  }
}
