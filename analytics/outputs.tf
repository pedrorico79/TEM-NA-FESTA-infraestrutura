output "lambda_pof_trends" {
  description = "Nome da Lambda semanal da base da EBD (infra dataset run pof-trends)."
  value       = aws_lambda_function.pof_trends.function_name
}

output "glue_database" {
  description = "Banco do Glue com as tabelas do bronze."
  value       = aws_glue_catalog_database.bronze.name
}

output "athena_workgroup" {
  description = "Workgroup do Athena com resultados obrigatórios e limite por consulta."
  value       = aws_athena_workgroup.tnf.name
}

output "athena_results_bucket" {
  description = "Bucket de resultados do Athena (criado pelo infra analytics up)."
  value       = local.results_bucket
}

output "glue_tables" {
  description = "Tabelas declaradas no Glue."
  value       = sort(keys(aws_glue_catalog_table.bronze))
}
