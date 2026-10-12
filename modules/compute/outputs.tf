output "nodes" {
  description = "Nós do Swarm: chave => ID, IP privado, AZ e papel."
  value = {
    for k, i in aws_instance.node : k => {
      id         = i.id
      hostname   = i.tags["Name"]
      private_ip = i.private_ip
      az         = i.availability_zone
      role       = i.tags["Role"]
    }
  }
}

output "bastion_public_ip" {
  description = "IP público do bastion (null sem bastion)."
  value       = try(aws_instance.bastion[0].public_ip, null)
}

output "ssh_public_key" {
  description = "Chave pública do ambiente (para conferir a cópia local)."
  value       = tls_private_key.ssh.public_key_openssh
}

output "ssh_private_key" {
  description = "Chave privada do ambiente, usada só pelo infra access (08, seção 5.6)."
  value       = tls_private_key.ssh.private_key_openssh
  sensitive   = true
}
