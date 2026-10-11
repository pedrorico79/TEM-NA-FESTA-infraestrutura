# T10 (03, seção 6): vpc_cidr = "10.0.0.0/16" é recusado; precisa ser /21.
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

run "T10_vpc_16_recusada" {
  command = plan

  module {
    source = "../../modules/environment"
  }

  variables {
    vpc_cidr = "10.0.0.0/16"
  }

  expect_failures = [var.vpc_cidr]
}

run "T10_vpc_21_aceita" {
  command = plan

  module {
    source = "../../modules/environment"
  }

  variables {
    vpc_cidr = "10.10.8.0/21"
  }

  assert {
    condition     = output.subnet_cidrs.public[0] == "10.10.8.0/24"
    error_message = "a subnet pública da AZ1 deve ser cidrsubnet(vpc_cidr, 3, 0)"
  }
}
