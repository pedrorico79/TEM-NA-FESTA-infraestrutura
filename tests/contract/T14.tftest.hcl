# T14 (03, seção 6): réplicas acima do número de nós do grupo são recusadas (backend com app_node_count = 1 e o análogo do frontend). Também verifica R9 (06).
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

run "T14_backend_maior_que_nos_app_recusado" {
  command = plan

  module {
    source = "../../modules/environment"
  }

  variables {
    service_replicas = { frontend = 1, backend = 2, messaging = 0 }
    app_node_count   = 1
  }

  expect_failures = [var.service_replicas]
}

run "T14_frontend_maior_que_nos_web_recusado" {
  command = plan

  module {
    source = "../../modules/environment"
  }

  variables {
    service_replicas = { frontend = 2, backend = 1, messaging = 0 }
    web_node_count   = 1
  }

  expect_failures = [var.service_replicas]
}

run "T14_replicas_iguais_aos_nos_aceitas" {
  command = plan

  module {
    source = "../../modules/environment"
  }

  variables {
    service_replicas = { frontend = 2, backend = 2, messaging = 0 }
    web_node_count   = 2
    app_node_count   = 2
  }
}
