output "endpoint" {
  description = "Endereço do RDS (sem a porta)."
  value       = aws_db_instance.this.address
}

output "port" {
  description = "Porta do RDS."
  value       = aws_db_instance.this.port
}

output "identifier" {
  description = "Identificador da instância do RDS."
  value       = aws_db_instance.this.identifier
}

output "cycle_id" {
  description = "Id do ciclo (8 hex), usado no nome do snapshot final."
  value       = random_id.cycle.hex
}
