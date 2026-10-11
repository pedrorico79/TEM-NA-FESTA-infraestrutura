# T2 (03, seção 6): region = "eu-west-1" é recusada; o laboratório só permite us-east-1 e us-west-2.
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

run "T2_regiao_fora_do_laboratorio_recusada" {
  command = plan

  module {
    source = "../../modules/environment"
  }

  variables {
    region = "eu-west-1"
  }

  expect_failures = [var.region]
}

run "T2_us_west_2_aceita" {
  command = plan

  module {
    source = "../../modules/environment"
  }

  variables {
    region   = "us-west-2"
    az_names = ["us-west-2a", "us-west-2b"]
  }
}
