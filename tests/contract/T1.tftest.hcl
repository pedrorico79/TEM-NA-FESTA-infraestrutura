# T1 (03, seção 6): env = "staging" é recusado; só dev ou prod.
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

run "T1_env_staging_recusado" {
  command = plan

  module {
    source = "../../modules/environment"
  }

  variables {
    env = "staging"
  }

  expect_failures = [var.env]
}

run "T1_env_prod_aceito" {
  command = plan

  module {
    source = "../../modules/environment"
  }

  variables {
    env = "prod"
  }
}
