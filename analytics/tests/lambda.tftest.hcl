# D1 e D2 (10, seção 11): a Lambda semanal da base da EBD, com o provedor AWS
# simulado; nenhuma chamada à AWS. Roda com: make analytics-test.

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "000000000000" }
  }
  mock_data "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::000000000000:role/LabRole" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

variables {
  dataset_ref     = "v1.0.0"
  lambda_zip_path = "/tmp/tnf-teste-inexistente.zip"
}

run "D1_lambda_da_ebd" {
  command = plan

  assert {
    condition = (
      aws_lambda_function.pof_trends.role == "arn:aws:iam::000000000000:role/LabRole" &&
      aws_lambda_function.pof_trends.runtime == "python3.12" &&
      aws_lambda_function.pof_trends.timeout == 900 &&
      aws_lambda_function.pof_trends.memory_size == 1024 &&
      aws_lambda_function.pof_trends.reserved_concurrent_executions == 1
    )
    error_message = "a Lambda precisa usar a LabRole, Python 3.12, 900 s, 1024 MB e concorrência 1"
  }

  assert {
    condition     = length(aws_lambda_function.pof_trends.vpc_config) == 0
    error_message = "a Lambda fica fora da VPC (sem NAT)"
  }

  assert {
    condition     = join(",", sort(keys(aws_lambda_function.pof_trends.environment[0].variables))) == "TNF_BRONZE_BUCKET,TNF_DATASET_REF"
    error_message = "as variáveis de ambiente da Lambda da EBD são só o bucket e a tag, sem segredo"
  }

  assert {
    condition     = aws_lambda_function.pof_trends.environment[0].variables["TNF_BRONZE_BUCKET"] == "bucket-bronze-000000000000-us-east-1"
    error_message = "a coleta grava no bucket bronze da conta"
  }

  assert {
    condition     = aws_cloudwatch_event_rule.pof_trends[0].schedule_expression == "cron(0 12 ? * MON *)"
    error_message = "a agenda padrão é semanal, segunda-feira às 09:00 de São Paulo"
  }

  assert {
    condition     = aws_lambda_function_event_invoke_config.pof_trends.maximum_retry_attempts == 0
    error_message = "sem novas tentativas automáticas da invocação"
  }

  assert {
    condition     = aws_cloudwatch_log_group.pof_trends.retention_in_days == 14
    error_message = "logs da Lambda com retenção de 14 dias"
  }
}

run "agenda_nula_nao_cria_regra" {
  command = plan

  variables {
    pof_trends_schedule = null
  }

  assert {
    condition     = length(aws_cloudwatch_event_rule.pof_trends) == 0 && length(aws_lambda_permission.pof_trends) == 0
    error_message = "com pof_trends_schedule = null não há regra do EventBridge"
  }
}

run "D2_dataset_ref_em_branco_recusado" {
  command = plan

  variables {
    dataset_ref = ""
  }

  expect_failures = [var.dataset_ref]
}

run "D2_dataset_ref_branch_recusado" {
  command = plan

  variables {
    dataset_ref = "main"
  }

  expect_failures = [var.dataset_ref]
}

run "D2_agenda_invalida_recusada" {
  command = plan

  variables {
    pof_trends_schedule = "toda segunda"
  }

  expect_failures = [var.pof_trends_schedule]
}
