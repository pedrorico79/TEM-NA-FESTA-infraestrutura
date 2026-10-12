# Security groups do ambiente (02, seção 5; 06). Só o ALB (80) e o bastion
# (22, do IP autorizado) recebem tráfego de fora da VPC. O tráfego do Swarm
# (2377/tcp, 7946/tcp+udp, 4789/udp) é liberado só entre membros do Swarm,
# inclusive entre swarm-web e swarm-app (A11). O rds aceita 3306 só do
# swarm-app. A regra de SSH do bastion é a única que o infra access altera
# (08, seção 5.6).

# As descrições enviadas à AWS ficam sem acento: a API do EC2 só aceita ASCII
# nas descrições de security groups e regras.
locals {
  groups = {
    alb       = "ALB publico (HTTP 80)"
    swarm_web = "Nos web do Swarm"
    swarm_app = "Nos app do Swarm"
    rds       = "RDS MySQL"
    bastion   = "Bastion (SSH)"
  }

  swarm_ports = {
    manager      = { port = 2377, protocol = "tcp" }
    gossip_tcp   = { port = 7946, protocol = "tcp" }
    gossip_udp   = { port = 7946, protocol = "udp" }
    overlay_vxln = { port = 4789, protocol = "udp" }
  }

  # Tráfego do Swarm: de cada grupo de nós para cada grupo de nós (web e app).
  swarm_rules = merge([
    for dst in ["swarm_web", "swarm_app"] : merge([
      for src in ["swarm_web", "swarm_app"] : {
        for name, p in local.swarm_ports : "${dst}-from-${src}-${name}" => {
          dst      = dst
          src      = src
          port     = p.port
          protocol = p.protocol
        }
      }
    ]...)
  ]...)

  # Demais entradas vindas de outro security group.
  sg_rules = {
    "swarm_web-http-from-alb"    = { dst = "swarm_web", src = "alb", port = 80, protocol = "tcp", why = "HTTP do ALB para o frontend" }
    "swarm_web-ssh-from-bastion" = { dst = "swarm_web", src = "bastion", port = 22, protocol = "tcp", why = "SSH vindo do bastion" }
    "swarm_app-ssh-from-bastion" = { dst = "swarm_app", src = "bastion", port = 22, protocol = "tcp", why = "SSH vindo do bastion" }
    "rds-mysql-from-swarm_app"   = { dst = "rds", src = "swarm_app", port = 3306, protocol = "tcp", why = "MySQL so dos nos app" }
  }
}

resource "aws_security_group" "this" {
  for_each = local.groups

  name        = "${var.name_prefix}-${replace(each.key, "_", "-")}"
  description = each.value
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name_prefix}-${replace(each.key, "_", "-")}" }
}

# --- Entradas ---------------------------------------------------------------------

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.this["alb"].id
  description       = "HTTP da internet"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

resource "aws_vpc_security_group_ingress_rule" "from_sg" {
  for_each = local.sg_rules

  security_group_id            = aws_security_group.this[each.value.dst].id
  description                  = each.value.why
  referenced_security_group_id = aws_security_group.this[each.value.src].id
  ip_protocol                  = each.value.protocol
  from_port                    = each.value.port
  to_port                      = each.value.port
}

resource "aws_vpc_security_group_ingress_rule" "swarm" {
  for_each = local.swarm_rules

  security_group_id            = aws_security_group.this[each.value.dst].id
  description                  = "Swarm ${each.value.port}/${each.value.protocol} de ${replace(each.value.src, "_", "-")}"
  referenced_security_group_id = aws_security_group.this[each.value.src].id
  ip_protocol                  = each.value.protocol
  from_port                    = each.value.port
  to_port                      = each.value.port
}

# SSH no bastion só de admin_ssh_cidrs (nunca 0.0.0.0/0, T9). Lista vazia:
# nenhuma entrada; o infra detecta o IP atual a partir da E4a (08, seção 5.6).
resource "aws_vpc_security_group_ingress_rule" "bastion_ssh" {
  for_each = toset(var.admin_ssh_cidrs)

  security_group_id = aws_security_group.this["bastion"].id
  description       = "SSH do IP autorizado"
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
}

# --- Saídas -----------------------------------------------------------------------
# Todos saem para qualquer destino, menos o rds, que não precisa de saída.

resource "aws_vpc_security_group_egress_rule" "all" {
  for_each = toset(["alb", "swarm_web", "swarm_app", "bastion"])

  security_group_id = aws_security_group.this[each.key].id
  description       = "Saida liberada"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
