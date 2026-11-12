# T18 (03, seção 6): os limites de login do backend (login_limits) são validados no plan e chegam ao stack.env.
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

run "T18_padroes_chegam_ao_stack_env" {
  command = plan

  module {
    source = "../../modules/environment"
  }

  assert {
    condition = (
      output.stack_env.LOGIN_MAX_POR_CONTA == "5" &&
      output.stack_env.LOGIN_MAX_POR_IP == "20" &&
      output.stack_env.LOGIN_JANELA_MINUTOS == "15" &&
      output.stack_env.LOGIN_BLOQUEIO_MINUTOS == "15"
    )
    error_message = "Sem login_limits, o stack.env deve trazer os padrões do backend (5, 20, 15 e 15)."
  }
}

run "T18_limite_por_ip_zero_desliga_a_regra" {
  command = plan

  module {
    source = "../../modules/environment"
  }

  variables {
    login_limits = { max_por_ip = 0 }
  }

  assert {
    condition = (
      output.stack_env.LOGIN_MAX_POR_IP == "0" &&
      output.stack_env.LOGIN_MAX_POR_CONTA == "5" &&
      output.stack_env.LOGIN_JANELA_MINUTOS == "15" &&
      output.stack_env.LOGIN_BLOQUEIO_MINUTOS == "15"
    )
    error_message = "max_por_ip = 0 vale como 0 no stack.env e os demais limites ficam nos padrões."
  }
}

run "T18_limite_por_ip_negativo_recusado" {
  command = plan

  module {
    source = "../../modules/environment"
  }

  variables {
    login_limits = { max_por_ip = -1 }
  }

  expect_failures = [var.login_limits]
}

run "T18_limite_por_conta_fracionado_recusado" {
  command = plan

  module {
    source = "../../modules/environment"
  }

  variables {
    login_limits = { max_por_conta = 1.5 }
  }

  expect_failures = [var.login_limits]
}

run "T18_janela_zero_recusada" {
  command = plan

  module {
    source = "../../modules/environment"
  }

  variables {
    login_limits = { janela_minutos = 0 }
  }

  expect_failures = [var.login_limits]
}

run "T18_bloqueio_zero_recusado" {
  command = plan

  module {
    source = "../../modules/environment"
  }

  variables {
    login_limits = { bloqueio_minutos = 0 }
  }

  expect_failures = [var.login_limits]
}
