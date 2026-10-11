# T3 (03, seção 6): az_count = 3 é recusado; os valores aceitos são 1 e 2. Também confere az_names com pelo menos 2 AZs (03, seção 3.1).
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

run "T3_az_count_3_recusado" {
  command = plan

  module {
    source = "../../modules/environment"
  }

  variables {
    az_count = 3
  }

  expect_failures = [var.az_count]
}

run "T3_az_count_2_aceito" {
  command = plan

  module {
    source = "../../modules/environment"
  }

  variables {
    az_count = 2
  }
}

run "T3_az_names_com_uma_az_recusada" {
  command = plan

  module {
    source = "../../modules/environment"
  }

  variables {
    az_names = ["us-east-1a"]
  }

  expect_failures = [var.az_names]
}

run "T3_az_names_com_duas_az_e_az_count_1_aceita" {
  command = plan

  module {
    source = "../../modules/environment"
  }

  variables {
    az_names = ["us-east-1b", "us-east-1c"]
  }

  assert {
    condition     = output.az_names == tolist(["us-east-1b", "us-east-1c"]) && output.active_az_names == tolist(["us-east-1b"])
    error_message = "com az_count = 1, as duas AZs servem às subnets públicas e de banco, e só a primeira recebe nós"
  }
}
