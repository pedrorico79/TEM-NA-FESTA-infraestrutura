# D3 (10, seção 11): tabelas do Glue com as colunas da seção 5, partition
# projection casando com os prefixos do bronze (10, seção 5; 05, B4) e o
# workgroup do Athena. Provedor AWS simulado.

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

run "D3_tabelas_e_projecao" {
  command = plan

  assert {
    condition = sort(keys(aws_glue_catalog_table.bronze)) == sort([
      "pof_trends_resumo", "pof_trends_serie", "pof_trends_rejeicoes",
      "tendencias_produtos_resumo", "tendencias_produtos_serie", "tendencias_produtos_rejeicoes",
      "logs_docker", "logs_auth", "logs_systemd",
    ])
    error_message = "o banco tnf_bronze tem as 9 tabelas de 10, seção 6.1"
  }

  assert {
    condition     = aws_glue_catalog_table.bronze["pof_trends_resumo"].parameters["storage.location.template"] == "s3://bucket-bronze-000000000000-us-east-1/datasets/pof_trends/resumo/data_coleta=$${data_coleta}/"
    error_message = "a projeção do resumo da EBD segue datasets/pof_trends/resumo/data_coleta=AAAA-MM-DD/"
  }

  assert {
    condition     = aws_glue_catalog_table.bronze["tendencias_produtos_serie"].parameters["storage.location.template"] == "s3://bucket-bronze-000000000000-us-east-1/datasets/tendencias_produtos/serie/env=$${env}/data_coleta=$${data_coleta}/"
    error_message = "a projeção dos produtos do sistema leva env e data_coleta"
  }

  assert {
    condition     = aws_glue_catalog_table.bronze["logs_docker"].parameters["storage.location.template"] == "s3://bucket-bronze-000000000000-us-east-1/logs/env=$${env}/source=docker/year=$${year}/month=$${month}/day=$${day}/"
    error_message = "a tabela de logs do Docker segue o layout de 05, B4"
  }

  assert {
    condition = (
      aws_glue_catalog_table.bronze["pof_trends_resumo"].parameters["projection.enabled"] == "true" &&
      aws_glue_catalog_table.bronze["pof_trends_resumo"].parameters["projection.data_coleta.type"] == "date" &&
      aws_glue_catalog_table.bronze["pof_trends_resumo"].parameters["projection.data_coleta.format"] == "yyyy-MM-dd" &&
      aws_glue_catalog_table.bronze["tendencias_produtos_resumo"].parameters["projection.env.values"] == "dev,prod"
    )
    error_message = "partition projection por data_coleta (yyyy-MM-dd) e env (dev, prod)"
  }

  assert {
    condition = sort([for c in aws_glue_catalog_table.bronze["pof_trends_resumo"].storage_descriptor[0].columns : c.name]) == sort([
      "produto_id", "produto_ibge", "termo_trends", "consumo_kg_sp", "popularidade_media", "popularidade_pico",
      "mes_pico", "fator_sazonalidade", "tipo_feriado_pico", "evento_associado",
    ])
    error_message = "o resumo da EBD tem os campos fixos do bruto (10, seção 5), sem repetir a partição"
  }

  assert {
    condition     = join(",", sort([for c in aws_glue_catalog_table.bronze["pof_trends_serie"].storage_descriptor[0].columns : c.name])) == "mes_parcial,mes_referencia,popularidade,produto_id"
    error_message = "a série tem produto, mês de referência, popularidade e mês parcial"
  }

  assert {
    condition = alltrue([
      for t in aws_glue_catalog_table.bronze : !contains([for c in t.storage_descriptor[0].columns : c.name], "data_coleta") && !contains([for c in t.storage_descriptor[0].columns : c.name], "env")
    ])
    error_message = "nenhuma coluna repete uma partição (data_coleta, env)"
  }

  assert {
    condition     = alltrue([for t in aws_glue_catalog_table.bronze : t.storage_descriptor[0].ser_de_info[0].serialization_library == "org.openx.data.jsonserde.JsonSerDe"])
    error_message = "as tabelas leem JSON Lines"
  }

  assert {
    condition = (
      aws_athena_workgroup.tnf.configuration[0].enforce_workgroup_configuration == true &&
      aws_athena_workgroup.tnf.configuration[0].bytes_scanned_cutoff_per_query == 1073741824 &&
      aws_athena_workgroup.tnf.configuration[0].result_configuration[0].output_location == "s3://tnf-athena-000000000000-us-east-1/resultados/"
    )
    error_message = "workgroup tnf com resultados obrigatórios no bucket de resultados e limite de 1 GB"
  }

  assert {
    condition     = aws_s3_bucket_lifecycle_configuration.results.rule[0].expiration[0].days == 30
    error_message = "resultados do Athena expiram em 30 dias"
  }
}
