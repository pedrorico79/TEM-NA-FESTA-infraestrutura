output "parameter_prefix" {
  description = "Caminho dos parâmetros SSM do ambiente (/tnf/<env>/secrets)."
  value       = local.prefix
}

output "parameter_names" {
  description = "Nomes dos parâmetros SSM criados (sem os valores)."
  value = concat(
    [for p in aws_ssm_parameter.generated : p.name],
    [for p in aws_ssm_parameter.fixed : p.name],
    [for p in aws_ssm_parameter.manual : p.name],
  )
}

output "db_admin_password" {
  description = "Senha do administrador do RDS, para o módulo database (E4b)."
  value       = random_password.this["db_admin_password"].result
  sensitive   = true
}
