# T11 (03, seção 6): db_allocated_storage_gb = 500 é recusado; o máximo é 100.
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

run "T11_armazenamento_500_recusado" {
  command = plan

  module {
    source = "../../modules/environment"
  }

  variables {
    db_allocated_storage_gb = 500
  }

  expect_failures = [var.db_allocated_storage_gb]
}

run "T11_armazenamento_100_aceito" {
  command = plan

  module {
    source = "../../modules/environment"
  }

  variables {
    db_allocated_storage_gb = 100
  }
}
