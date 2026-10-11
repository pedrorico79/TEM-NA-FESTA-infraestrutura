output "name_prefix" {
  description = "Prefixo dos nomes de recursos: <project_name>-<env>."
  value       = local.prefix
}

output "az_names" {
  description = "As duas AZs do ambiente [AZ1, AZ2]; as subnets públicas e de banco usam as duas."
  value       = local.az_list

  precondition {
    condition     = length(local.az_list) == 2
    error_message = "São necessárias 2 AZs (o ALB e o RDS exigem duas), mas só ${length(local.az_list)} foi encontrada ou informada. Informe az_names com duas AZs da região ou escolha tipos de instância oferecidos em mais AZs."
  }
}

output "active_az_names" {
  description = "As az_count primeiras AZs, que recebem nós web e app."
  value       = local.active_az_list
}

output "subnet_cidrs" {
  description = "CIDRs das subnets por camada, na ordem [AZ1, AZ2] (03, seção 5)."
  value       = local.subnet_cidrs
}

output "nodes" {
  description = "Nós do Swarm por chave estável (web-1, app-1...): grupo, hostname, AZ, subnet, IP fixo e papel de manager."
  value       = local.nodes
}

output "bastion" {
  description = "Bastion (hostname, AZ e subnet pública da AZ1), ou null se bastion_enabled = false."
  value       = local.bastion
}

output "instance_count" {
  description = "Instâncias EC2 planejadas: nós web, nós app e bastion."
  value       = local.instance_count
}

output "expected_nodes" {
  description = "Hostnames dos nós do Swarm que devem existir (EXPECTED_NODES), sem o bastion."
  value       = local.expected_nodes
}

output "manager_nodes" {
  description = "Hostnames dos managers: os manager_count primeiros nós app."
  value       = local.manager_nodes
}

output "stack_env" {
  description = "Valores do stack.env calculados nesta etapa (sem DB_ENDPOINT, que vem do módulo database na E4b)."
  value       = local.stack_env
}

output "ssh_private_key_path" {
  description = "Caminho local da chave SSH privada do ambiente."
  value       = local.ssh_private_key_path
}
