output "vpc_id" {
  description = "ID da VPC."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "CIDR da VPC."
  value       = aws_vpc.this.cidr_block
}

output "subnet_ids" {
  description = "IDs das subnets por camada, na ordem das AZs: public e db com duas; web e app com az_count."
  value = {
    for tier in ["public", "web", "app", "db"] : tier => [
      for key in sort(keys(aws_subnet.this)) : aws_subnet.this[key].id
      if startswith(key, "${tier}-")
    ]
  }
}

output "subnet_cidrs" {
  description = "CIDRs das subnets por camada, na mesma ordem de subnet_ids."
  value = {
    for tier in ["public", "web", "app", "db"] : tier => [
      for key in sort(keys(aws_subnet.this)) : aws_subnet.this[key].cidr_block
      if startswith(key, "${tier}-")
    ]
  }
}

output "nat_public_ips" {
  description = "Elastic IPs das NATs, por AZ (a saída dos nós para a internet)."
  value       = { for k, e in aws_eip.nat : k => e.public_ip }
}

output "nat_route_ids" {
  description = "Rotas privadas pela NAT; as instâncias dependem delas (04, seção 4)."
  value       = [for r in aws_route.private_nat : r.id]
}
