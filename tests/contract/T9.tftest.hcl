# T9 (03, seção 6): admin_ssh_cidrs com 0.0.0.0/0 é recusada: SSH aberto para o mundo é proibido.
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

run "T9_ssh_aberto_recusado" {
  command = plan

  module {
    source = "../../modules/environment"
  }

  variables {
    admin_ssh_cidrs = ["0.0.0.0/0"]
  }

  expect_failures = [var.admin_ssh_cidrs]
}

run "T9_ssh_aberto_junto_de_outro_ip_recusado" {
  command = plan

  module {
    source = "../../modules/environment"
  }

  variables {
    admin_ssh_cidrs = ["203.0.113.10/32", "0.0.0.0/0"]
  }

  expect_failures = [var.admin_ssh_cidrs]
}

run "T9_ip_unico_aceito" {
  command = plan

  module {
    source = "../../modules/environment"
  }

  variables {
    admin_ssh_cidrs = ["203.0.113.10/32"]
  }
}
