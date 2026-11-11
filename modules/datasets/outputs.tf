output "function_name" {
  description = "Nome da Lambda de coleta do ambiente (infra dataset run <env>)."
  value       = aws_lambda_function.this.function_name
}
