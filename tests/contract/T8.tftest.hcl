# T8 (03, seção 6): db_instance_class = "db.t3.large" é recusada; o tamanho máximo é medium.
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

run "T8_db_large_recusada" {
  command = plan

  module {
    source = "../../modules/environment"
  }

  variables {
    db_instance_class = "db.t3.large"
  }

  expect_failures = [var.db_instance_class]
}

run "T8_db_medium_aceita" {
  command = plan

  module {
    source = "../../modules/environment"
  }

  variables {
    db_instance_class = "db.t3.medium"
  }
}
