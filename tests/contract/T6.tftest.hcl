# T6 (03, seção 6): web_node_count = 5 e app_node_count = 5 excedem ec2_instance_limit.
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

run "T6_excede_limite_recusado" {
  command = plan

  module {
    source = "../../modules/environment"
  }

  variables {
    web_node_count = 5
    app_node_count = 5
  }

  expect_failures = [var.ec2_instance_limit]
}

run "T6_limite_exato_aceito" {
  command = plan

  module {
    source = "../../modules/environment"
  }

  variables {
    web_node_count = 4
    app_node_count = 4
  }

  assert {
    condition     = output.instance_count == 9
    error_message = "4 web + 4 app + bastion devem dar 9 instâncias"
  }
}

run "T6_sem_bastion_libera_uma_instancia" {
  command = plan

  module {
    source = "../../modules/environment"
  }

  variables {
    web_node_count  = 4
    app_node_count  = 5
    bastion_enabled = false
  }

  assert {
    condition     = output.instance_count == 9
    error_message = "sem bastion, 4 web + 5 app devem dar 9 instâncias"
  }

  assert {
    condition     = output.bastion == null
    error_message = "sem bastion, a saída bastion deve ser null"
  }
}
