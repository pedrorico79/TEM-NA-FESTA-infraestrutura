# T15 (03, seção 6): (a) db_schema_ref com nome de branch é recusado, com ou sem snapshot; (b) dockerhub_namespace em branco e (c) db_schema_* em branco sem snapshot são recusados, todas na mesma execução.
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

run "T15a_branch_main_recusada" {
  command = plan

  module {
    source = "../../modules/environment"
  }

  variables {
    db_schema_ref = "main"
  }

  expect_failures = [var.db_schema_ref]
}

run "T15a_branch_main_recusada_com_snapshot" {
  command = plan

  module {
    source = "../../modules/environment"
  }

  variables {
    db_schema_ref          = "main"
    db_snapshot_identifier = "tem-na-festa-dev-final-0a1b2c3d"
  }

  expect_failures = [var.db_schema_ref]
}

run "T15a_branch_master_recusada" {
  command = plan

  module {
    source = "../../modules/environment"
  }

  variables {
    db_schema_ref = "master"
  }

  expect_failures = [var.db_schema_ref]
}

run "T15a_branch_master_recusada_com_snapshot" {
  command = plan

  module {
    source = "../../modules/environment"
  }

  variables {
    db_schema_ref          = "master"
    db_snapshot_identifier = "tem-na-festa-dev-final-0a1b2c3d"
  }

  expect_failures = [var.db_schema_ref]
}

run "T15a_branch_develop_recusada" {
  command = plan

  module {
    source = "../../modules/environment"
  }

  variables {
    db_schema_ref = "develop"
  }

  expect_failures = [var.db_schema_ref]
}

run "T15a_branch_develop_recusada_com_snapshot" {
  command = plan

  module {
    source = "../../modules/environment"
  }

  variables {
    db_schema_ref          = "develop"
    db_snapshot_identifier = "tem-na-festa-dev-final-0a1b2c3d"
  }

  expect_failures = [var.db_schema_ref]
}

run "T15a_branch_head_recusada" {
  command = plan

  module {
    source = "../../modules/environment"
  }

  variables {
    db_schema_ref = "HEAD"
  }

  expect_failures = [var.db_schema_ref]
}

run "T15a_branch_head_recusada_com_snapshot" {
  command = plan

  module {
    source = "../../modules/environment"
  }

  variables {
    db_schema_ref          = "HEAD"
    db_snapshot_identifier = "tem-na-festa-dev-final-0a1b2c3d"
  }

  expect_failures = [var.db_schema_ref]
}

run "T15b_dockerhub_namespace_em_branco_recusado" {
  command = plan

  module {
    source = "../../modules/environment"
  }

  variables {
    dockerhub_namespace = ""
  }

  expect_failures = [var.dockerhub_namespace]
}

run "T15c_db_schema_em_branco_sem_snapshot_recusadas" {
  command = plan

  module {
    source = "../../modules/environment"
  }

  variables {
    db_schema_repo_url = ""
    db_schema_ref      = ""
    db_schema_path     = ""
  }

  expect_failures = [var.db_schema_repo_url, var.db_schema_ref, var.db_schema_path]
}

run "T15c_db_schema_ref_em_branco_sem_snapshot_recusada" {
  command = plan

  module {
    source = "../../modules/environment"
  }

  variables {
    db_schema_ref = ""
  }

  expect_failures = [var.db_schema_ref]
}

run "T15bc_todas_as_que_faltam_na_mesma_execucao" {
  command = plan

  module {
    source = "../../modules/environment"
  }

  variables {
    dockerhub_namespace = ""
    db_schema_repo_url  = ""
    db_schema_ref       = ""
    db_schema_path      = ""
  }

  expect_failures = [var.dockerhub_namespace, var.db_schema_repo_url, var.db_schema_ref, var.db_schema_path]
}
