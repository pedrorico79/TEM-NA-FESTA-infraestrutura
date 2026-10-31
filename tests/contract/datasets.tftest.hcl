# D1, D2 e D10 (10, seção 11): o módulo datasets do ambiente, com o provedor
# AWS simulado. A Lambda dos produtos do sistema só existe com
# datasets_enabled = true, usa a LabRole e lê o email e a senha do SSM, nunca
# das variáveis de ambiente.

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

run "datasets_desligado_por_padrao" {
  command = plan

  module {
    source = "../../modules/environment"
  }

  assert {
    condition     = length(module.datasets) == 0 && output.dataset_function_name == null
    error_message = "sem datasets_enabled, não há Lambda de coleta no ambiente"
  }
}

run "D1_D10_lambda_do_ambiente" {
  command = plan

  module {
    source = "../../modules/environment"
  }

  variables {
    datasets_enabled = true
    dataset_ref      = "v1.0.0"
    dataset_secrets  = { dataset_api_email = "coleta@exemplo.invalid", dataset_api_password = "senha-de-teste" }
  }

  assert {
    condition = (
      module.datasets[0].function_name == "tnf-dev-tendencias" &&
      output.dataset_function_name == "tnf-dev-tendencias"
    )
    error_message = "a Lambda do ambiente se chama tnf-<env>-tendencias"
  }
}

run "D1_D10_lambda_do_ambiente_no_modulo" {
  command = plan

  module {
    source = "../../modules/datasets"
  }

  variables {
    env                  = "dev"
    region               = "us-east-1"
    bronze_bucket        = "bucket-bronze-000000000000-us-east-1"
    api_url              = "http://alb.exemplo.invalid/api/v1"
    dataset_ref          = "v1.0.0"
    lambda_zip_path      = "/tmp/tnf-teste-inexistente.zip"
    pandas_layer_version = 17
    reserved_concurrency = 1
    secrets              = { dataset_api_email = "coleta@exemplo.invalid", dataset_api_password = "senha-de-teste" }
  }

  assert {
    condition = (
      aws_lambda_function.this.role == "arn:aws:iam::000000000000:role/LabRole" &&
      aws_lambda_function.this.runtime == "python3.12" &&
      aws_lambda_function.this.timeout == 900 &&
      aws_lambda_function.this.reserved_concurrent_executions == 1 &&
      length(aws_lambda_function.this.vpc_config) == 0
    )
    error_message = "LabRole, Python 3.12, 900 s, concorrência 1 e fora da VPC"
  }

  assert {
    condition     = join(",", sort(keys(aws_lambda_function.this.environment[0].variables))) == "TNF_API_URL,TNF_BRONZE_BUCKET,TNF_ENV,TNF_SSM_PREFIX"
    error_message = "as variáveis da função são só bucket, URL da API, ambiente e prefixo do SSM"
  }

  assert {
    condition = alltrue([
      for v in values(aws_lambda_function.this.environment[0].variables) : !strcontains(v, "senha-de-teste") && !strcontains(v, "coleta@exemplo.invalid")
    ])
    error_message = "D10: o email e a senha da coleta não aparecem nas variáveis da função"
  }

  assert {
    condition = (
      aws_ssm_parameter.secret["dataset_api_password"].type == "SecureString" &&
      aws_ssm_parameter.secret["dataset_api_password"].name == "/tnf/dev/datasets/dataset_api_password"
    )
    error_message = "os segredos da coleta ficam no SSM, como SecureString, em /tnf/<env>/datasets/"
  }

  assert {
    condition     = length(aws_cloudwatch_event_rule.this) == 0
    error_message = "sem agenda (dataset_schedule = null), não há regra do EventBridge"
  }
}

run "D2_dataset_ref_em_branco_recusado" {
  command = plan

  module {
    source = "../../modules/environment"
  }

  variables {
    datasets_enabled = true
    dataset_secrets  = { dataset_api_email = "coleta@exemplo.invalid", dataset_api_password = "senha-de-teste" }
  }

  expect_failures = [var.dataset_ref]
}

run "D2_agenda_invalida_recusada" {
  command = plan

  module {
    source = "../../modules/environment"
  }

  variables {
    datasets_enabled = true
    dataset_ref      = "v1.0.0"
    dataset_schedule = "toda segunda"
    dataset_secrets  = { dataset_api_email = "coleta@exemplo.invalid", dataset_api_password = "senha-de-teste" }
  }

  expect_failures = [var.dataset_schedule]
}

run "datasets_sem_segredos_recusado" {
  command = plan

  module {
    source = "../../modules/environment"
  }

  variables {
    datasets_enabled = true
    dataset_ref      = "v1.0.0"
  }

  expect_failures = [var.dataset_secrets]
}
