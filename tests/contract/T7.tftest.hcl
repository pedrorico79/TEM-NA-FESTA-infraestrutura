# T7 (03, seção 6): app_instance_type = "t3.xlarge" é recusado; o tamanho máximo é large.
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

run "T7_app_xlarge_recusado" {
  command = plan

  module {
    source = "../../modules/environment"
  }

  variables {
    app_instance_type = "t3.xlarge"
  }

  expect_failures = [var.app_instance_type]
}

run "T7_web_e_bastion_xlarge_recusados" {
  command = plan

  module {
    source = "../../modules/environment"
  }

  variables {
    web_instance_type     = "t3.2xlarge"
    bastion_instance_type = "m5.xlarge"
  }

  expect_failures = [var.web_instance_type, var.bastion_instance_type]
}

run "T7_large_aceito" {
  command = plan

  module {
    source = "../../modules/environment"
  }

  variables {
    app_instance_type = "t3.large"
    az_names          = ["us-east-1a", "us-east-1b"]
  }
}
