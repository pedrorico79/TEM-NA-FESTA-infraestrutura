# Glue Data Catalog (10, seção 6.1): banco tnf_bronze com as tabelas
# declaradas aqui e partition projection. As partições são calculadas pelo
# Athena a partir do caminho no bronze (layouts de 10, seção 5, e 05, B4):
# uma coleta nova aparece na consulta sem crawler e sem MSCK REPAIR.
# Colunas que já são partição (data_coleta, env) não se repetem no schema.

resource "aws_glue_catalog_database" "bronze" {
  name        = "tnf_bronze"
  description = "Bronze do Tem Na Festa: coletas de tendências e logs dos nós (10)"
}

locals {
  bronze = "s3://${local.bronze_bucket_name}"

  metricas = {
    popularidade_media = "double"
    popularidade_pico  = "double"
    mes_pico           = "int"
    fator_sazonalidade = "double"
    tipo_feriado_pico  = "string"
    evento_associado   = "string"
  }

  serie = {
    produto_id     = "int"
    mes_referencia = "string"
    popularidade   = "double"
    mes_parcial    = "boolean"
  }

  rejeicoes = {
    produto_id      = "int"
    produto         = "string"
    regra           = "string"
    motivo          = "string"
    severidade      = "string"
    data_ocorrencia = "string"
  }

  # Projeção das partições de cada layout.
  proj_coleta = {
    "projection.data_coleta.type"          = "date"
    "projection.data_coleta.format"        = "yyyy-MM-dd"
    "projection.data_coleta.range"         = "2026-01-01,NOW"
    "projection.data_coleta.interval"      = "1"
    "projection.data_coleta.interval.unit" = "DAYS"
  }
  proj_env = {
    "projection.env.type"   = "enum"
    "projection.env.values" = join(",", var.dataset_envs)
  }
  proj_dia = {
    "projection.year.type"    = "integer"
    "projection.year.range"   = "2026,2036"
    "projection.month.type"   = "integer"
    "projection.month.range"  = "1,12"
    "projection.month.digits" = "2"
    "projection.day.type"     = "integer"
    "projection.day.range"    = "1,31"
    "projection.day.digits"   = "2"
  }

  coleta     = ["data_coleta"]
  env_coleta = ["env", "data_coleta"]
  env_dia    = ["env", "year", "month", "day"]

  tabelas = {
    pof_trends_resumo = {
      descricao  = "Base da EBD: uma linha por produto da POF por coleta (10, seção 5)"
      prefixo    = "datasets/pof_trends/resumo"
      particoes  = local.coleta
      template   = "data_coleta=$${data_coleta}"
      projecao   = local.proj_coleta
      colunas    = merge({ produto_id = "int", produto_ibge = "string", termo_trends = "string", consumo_kg_sp = "double" }, local.metricas)
      mapeamento = {}
    }
    pof_trends_serie = {
      descricao  = "Base da EBD: popularidade por produto e mês de referência"
      prefixo    = "datasets/pof_trends/serie"
      particoes  = local.coleta
      template   = "data_coleta=$${data_coleta}"
      projecao   = local.proj_coleta
      colunas    = local.serie
      mapeamento = {}
    }
    pof_trends_rejeicoes = {
      descricao  = "Base da EBD: rejeições das regras de validação (EBD, seção 4.2)"
      prefixo    = "datasets/pof_trends/rejeicoes"
      particoes  = local.coleta
      template   = "data_coleta=$${data_coleta}"
      projecao   = local.proj_coleta
      colunas    = local.rejeicoes
      mapeamento = {}
    }
    tendencias_produtos_resumo = {
      descricao  = "Produtos do sistema: uma linha por produto por coleta e ambiente"
      prefixo    = "datasets/tendencias_produtos/resumo"
      particoes  = local.env_coleta
      template   = "env=$${env}/data_coleta=$${data_coleta}"
      projecao   = merge(local.proj_env, local.proj_coleta)
      colunas    = merge({ produto_id = "int", produto_nome = "string", preco_venda = "double" }, local.metricas)
      mapeamento = {}
    }
    tendencias_produtos_serie = {
      descricao  = "Produtos do sistema: popularidade por produto e mês de referência"
      prefixo    = "datasets/tendencias_produtos/serie"
      particoes  = local.env_coleta
      template   = "env=$${env}/data_coleta=$${data_coleta}"
      projecao   = merge(local.proj_env, local.proj_coleta)
      colunas    = local.serie
      mapeamento = {}
    }
    tendencias_produtos_rejeicoes = {
      descricao  = "Produtos do sistema: rejeições e avisos (Sem dados suficientes)"
      prefixo    = "datasets/tendencias_produtos/rejeicoes"
      particoes  = local.env_coleta
      template   = "env=$${env}/data_coleta=$${data_coleta}"
      projecao   = merge(local.proj_env, local.proj_coleta)
      colunas    = local.rejeicoes
      mapeamento = {}
    }
    logs_docker = {
      descricao  = "Logs dos containers dos nós web e app (05, B4; 02, seção 7.1)"
      prefixo    = "logs"
      particoes  = local.env_dia
      template   = "env=$${env}/source=docker/year=$${year}/month=$${month}/day=$${day}"
      projecao   = merge(local.proj_env, local.proj_dia)
      colunas    = { date = "string", log = "string", stream = "string", attrs = "map<string,string>", host = "string", role = "string", log_file = "string" }
      mapeamento = {}
    }
    logs_auth = {
      descricao  = "auth.log de todas as instâncias, inclusive o bastion (05, B4)"
      prefixo    = "logs"
      particoes  = local.env_dia
      template   = "env=$${env}/source=auth/year=$${year}/month=$${month}/day=$${day}"
      projecao   = merge(local.proj_env, local.proj_dia)
      colunas    = { date = "string", ident = "string", pid = "string", message = "string", host = "string", role = "string" }
      mapeamento = {}
    }
    logs_systemd = {
      descricao  = "Unidades do systemd da lista de 02, seção 7.1 (05, B4)"
      prefixo    = "logs"
      particoes  = local.env_dia
      template   = "env=$${env}/source=systemd/year=$${year}/month=$${month}/day=$${day}"
      projecao   = merge(local.proj_env, local.proj_dia)
      colunas    = { date = "string", message = "string", systemd_unit = "string", priority = "string", host = "string", role = "string" }
      mapeamento = { "mapping.systemd_unit" = "_systemd_unit" }
    }
  }
}

resource "aws_glue_catalog_table" "bronze" {
  for_each = local.tabelas

  name          = each.key
  database_name = aws_glue_catalog_database.bronze.name
  description   = each.value.descricao
  table_type    = "EXTERNAL_TABLE"

  parameters = merge(
    {
      "classification"            = "json"
      "EXTERNAL"                  = "TRUE"
      "projection.enabled"        = "true"
      "storage.location.template" = "${local.bronze}/${each.value.prefixo}/${each.value.template}/"
    },
    each.value.projecao,
  )

  dynamic "partition_keys" {
    for_each = each.value.particoes
    content {
      name = partition_keys.value
      type = contains(["year", "month", "day"], partition_keys.value) ? "int" : "string"
    }
  }

  storage_descriptor {
    location      = "${local.bronze}/${each.value.prefixo}/"
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"

    ser_de_info {
      name                  = "json"
      serialization_library = "org.openx.data.jsonserde.JsonSerDe"
      parameters = merge(
        { "ignore.malformed.json" = "true", "case.insensitive" = "true" },
        each.value.mapeamento,
      )
    }

    dynamic "columns" {
      for_each = each.value.colunas
      content {
        name = columns.key
        type = columns.value
      }
    }
  }
}
