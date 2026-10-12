output "security_group_ids" {
  description = "IDs dos security groups: alb, swarm_web, swarm_app, rds e bastion."
  value       = { for k, sg in aws_security_group.this : k => sg.id }
}
