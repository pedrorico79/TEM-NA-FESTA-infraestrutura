output "dns_name" {
  description = "Nome DNS do ALB: o endereço do sistema (RF-11)."
  value       = aws_lb.this.dns_name
}

output "target_group_arn" {
  description = "ARN do target group dos nós web."
  value       = aws_lb_target_group.web.arn
}
