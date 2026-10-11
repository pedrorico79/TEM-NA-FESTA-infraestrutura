# Contrato de variáveis do ambiente (03). Os padrões são os de dev; prod
# muda os seus no envs/prod/terraform.tfvars. As variáveis com padrão usam
# nullable = false para que a raiz possa repassar null e o padrão valer.

# --- 3.1 Identidade e região ---------------------------------------------------

variable "env" {
  description = "Nome do ambiente: dev ou prod."
  type        = string

  validation {
    condition     = contains(["dev", "prod"], var.env)
    error_message = "env deve ser \"dev\" ou \"prod\" (03, seção 3.1)."
  }
}

variable "project_name" {
  description = "Nome do projeto, usado no prefixo dos recursos (<project_name>-<env>)."
  type        = string
  default     = "tem-na-festa"
  nullable    = false

  validation {
    condition     = can(regex("^[a-z0-9]+(-[a-z0-9]+)*$", var.project_name))
    error_message = "project_name aceita só letras minúsculas, números e hífen (sem hífen no começo, no fim ou repetido)."
  }
}

# tflint-ignore: terraform_unused_declarations # provedor da raiz; usada pelos módulos a partir da E3
variable "region" {
  description = "Região da AWS do ambiente."
  type        = string
  default     = "us-east-1"
  nullable    = false

  validation {
    condition     = contains(["us-east-1", "us-west-2"], var.region)
    error_message = "region inválida: o laboratório só permite us-east-1 e us-west-2 (03, seção 3.1)."
  }
}

variable "vpc_cidr" {
  description = "CIDR da VPC; precisa ser /21, pois as subnets são derivadas dele (03, seção 5)."
  type        = string
  default     = "10.0.0.0/21"
  nullable    = false

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr)) && endswith(var.vpc_cidr, "/21")
    error_message = "vpc_cidr precisa ser um bloco IPv4 /21 (por exemplo 10.0.0.0/21): a divisão em subnets depende disso."
  }
}

variable "az_names" {
  description = "AZs a usar, em ordem (pelo menos 2). Se null, usa as primeiras AZs disponíveis na região que oferecem os tipos de instância escolhidos."
  type        = list(string)
  default     = null

  validation {
    condition     = var.az_names == null || try(length(var.az_names) >= 2, false)
    error_message = "az_names, quando informada, precisa ter pelo menos 2 AZs: as subnets públicas e de banco sempre usam duas (o ALB e o RDS exigem), e só as az_count primeiras recebem nós web e app (03, seção 3.1)."
  }
}

# --- 3.2 Topologia ---------------------------------------------------------------

variable "az_count" {
  description = "Quantidade de AZs com nós web e app: 1 ou 2."
  type        = number
  default     = 1
  nullable    = false

  validation {
    condition     = contains([1, 2], var.az_count)
    error_message = "az_count inválido: os valores aceitos são 1 e 2 (03, seção 3.2)."
  }
}

# tflint-ignore: terraform_unused_declarations # usada pelo módulo network (E3)
variable "nat_mode" {
  description = "single (uma NAT, na AZ1) ou per_az (uma NAT por AZ ativa)."
  type        = string
  default     = "single"
  nullable    = false

  validation {
    condition     = contains(["single", "per_az"], var.nat_mode)
    error_message = "nat_mode deve ser \"single\" ou \"per_az\" (03, seção 3.2)."
  }
}

variable "web_node_count" {
  description = "Total de nós web, distribuídos em rodízio pelas AZs ativas."
  type        = number
  default     = 1
  nullable    = false

  validation {
    condition     = var.web_node_count >= 1 && floor(var.web_node_count) == var.web_node_count
    error_message = "web_node_count precisa ser um número inteiro maior ou igual a 1."
  }
}

variable "app_node_count" {
  description = "Total de nós app, distribuídos em rodízio pelas AZs ativas."
  type        = number
  default     = 1
  nullable    = false

  validation {
    condition     = var.app_node_count >= 1 && floor(var.app_node_count) == var.app_node_count
    error_message = "app_node_count precisa ser um número inteiro maior ou igual a 1."
  }
}

variable "manager_count" {
  description = "Managers do Swarm (os primeiros nós app): 1, 3 ou 5, no máximo app_node_count. Fixo durante a vida do ambiente."
  type        = number
  default     = 1
  nullable    = false

  validation {
    condition     = contains([1, 3, 5], var.manager_count)
    error_message = "manager_count inválido: o número de managers deve ser ímpar (1, 3 ou 5) para o Swarm ter quórum (03, seção 3.2)."
  }

  validation {
    condition     = var.manager_count <= var.app_node_count
    error_message = "manager_count não pode exceder app_node_count: os managers são os primeiros nós app. Aumente app_node_count ou reduza manager_count."
  }
}

variable "bastion_enabled" {
  description = "Se false, não há bastion (libera uma instância do limite, mas remove o acesso de depuração)."
  type        = bool
  default     = true
  nullable    = false
}

# tflint-ignore: terraform_unused_declarations # só nas validações; não vira recurso
variable "ec2_instance_limit" {
  description = "Limite de instâncias EC2 deste ambiente (9 é o limite por região do laboratório, RES-05)."
  type        = number
  default     = 9
  nullable    = false

  validation {
    condition     = var.ec2_instance_limit >= 1 && floor(var.ec2_instance_limit) == var.ec2_instance_limit
    error_message = "ec2_instance_limit precisa ser um número inteiro maior ou igual a 1."
  }

  validation {
    condition     = var.web_node_count + var.app_node_count + (var.bastion_enabled ? 1 : 0) <= var.ec2_instance_limit
    error_message = "A topologia excede ec2_instance_limit: web_node_count + app_node_count + bastion (${var.web_node_count} + ${var.app_node_count} + ${var.bastion_enabled ? 1 : 0}) passa de ${var.ec2_instance_limit}. Reduza os nós ou, fora do laboratório, aumente ec2_instance_limit."
  }
}

# --- 3.3 Instâncias --------------------------------------------------------------

variable "web_instance_type" {
  description = "Tipo das instâncias web (tamanho nano a large)."
  type        = string
  default     = "t3.micro"
  nullable    = false

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]*\\.(nano|micro|small|medium|large)$", var.web_instance_type))
    error_message = "web_instance_type inválido: o tamanho máximo é large (nano, micro, small, medium ou large; por exemplo t3.micro)."
  }
}

variable "app_instance_type" {
  description = "Tipo das instâncias app (tamanho nano a large)."
  type        = string
  default     = "t3.small"
  nullable    = false

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]*\\.(nano|micro|small|medium|large)$", var.app_instance_type))
    error_message = "app_instance_type inválido: o tamanho máximo é large (nano, micro, small, medium ou large; por exemplo t3.small)."
  }
}

variable "bastion_instance_type" {
  description = "Tipo da instância do bastion (tamanho nano a large)."
  type        = string
  default     = "t3.micro"
  nullable    = false

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]*\\.(nano|micro|small|medium|large)$", var.bastion_instance_type))
    error_message = "bastion_instance_type inválido: o tamanho máximo é large (nano, micro, small, medium ou large; por exemplo t3.micro)."
  }
}

# tflint-ignore: terraform_unused_declarations # usada pelo módulo compute (E4a)
variable "root_volume_size_gb" {
  description = "Tamanho do volume raiz (gp3) das instâncias, em GB."
  type        = number
  default     = 20
  nullable    = false

  validation {
    condition     = var.root_volume_size_gb >= 8 && var.root_volume_size_gb <= 100 && floor(var.root_volume_size_gb) == var.root_volume_size_gb
    error_message = "root_volume_size_gb precisa ser um inteiro de 8 a 100."
  }
}

# tflint-ignore: terraform_unused_declarations # usada pelo módulo compute (E4a)
variable "ami_id" {
  description = "AMI Ubuntu 24.04 LTS. Se null, usa a mais recente da Canonical na região, no momento em que o nó é criado."
  type        = string
  default     = null

  validation {
    condition     = var.ami_id == null || can(regex("^ami-[0-9a-f]{8,17}$", var.ami_id))
    error_message = "ami_id deve ser null ou um ID de AMI (ami- seguido de 8 a 17 caracteres hexadecimais), da mesma região do ambiente."
  }
}

# --- 3.4 Serviços e imagens ------------------------------------------------------

variable "service_replicas" {
  description = "Réplicas por serviço. messaging = 0 deixa a mensageria desligada (até a E8)."
  type = object({
    frontend  = number
    backend   = number
    messaging = number
  })
  default = {
    frontend  = 1
    backend   = 1
    messaging = 0
  }
  nullable = false

  validation {
    condition     = var.service_replicas.frontend >= 1 && var.service_replicas.backend >= 1
    error_message = "service_replicas: frontend e backend precisam de ao menos 1 réplica; só a mensageria pode ficar em 0 (03, seção 3.4)."
  }

  validation {
    condition     = contains([0, 1], var.service_replicas.messaging)
    error_message = "service_replicas.messaging só pode ser 0 (desligada) ou 1: o microsserviço de mensageria ainda não foi confirmado como seguro com mais de uma réplica (03, seção 3.4)."
  }

  validation {
    condition     = var.service_replicas.frontend <= var.web_node_count && var.service_replicas.backend <= var.app_node_count
    error_message = "service_replicas não pode exceder o número de nós do grupo (no máximo 1 réplica por nó): frontend ≤ web_node_count (${var.web_node_count}) e backend ≤ app_node_count (${var.app_node_count}). Reduza as réplicas ou aumente os nós."
  }

  validation {
    condition = alltrue([
      for n in values(var.service_replicas) : floor(n) == n
    ])
    error_message = "service_replicas aceita só números inteiros."
  }
}

variable "image_tags" {
  description = "Etiquetas das imagens na primeira subida do ambiente (dev, prod ou sha-<7>)."
  type = object({
    frontend  = string
    backend   = string
    messaging = string
  })
  default = {
    frontend  = "dev"
    backend   = "dev"
    messaging = "dev"
  }
  nullable = false

  validation {
    condition = alltrue([
      for t in values(var.image_tags) : can(regex("^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$", t))
    ])
    error_message = "image_tags: cada etiqueta precisa ser uma tag válida do Docker (letras, números, _, . e -; por exemplo dev, prod ou sha-abc1234)."
  }
}

variable "dockerhub_namespace" {
  description = "Usuário ou organização do Docker Hub com os repositórios tnf-frontend, tnf-backend e tnf-messaging (públicos)."
  type        = string
  nullable    = false

  validation {
    condition     = var.dockerhub_namespace != ""
    error_message = "Preencha dockerhub_namespace em envs/${var.env}/terraform.tfvars (usuário ou organização do Docker Hub)."
  }

  validation {
    condition     = var.dockerhub_namespace == "" || can(regex("^[a-z0-9]+([._-][a-z0-9]+)*$", var.dockerhub_namespace))
    error_message = "dockerhub_namespace inválido: use o nome do usuário ou da organização do Docker Hub (letras minúsculas e números)."
  }
}

variable "messaging_port" {
  description = "Porta em que o microsserviço de mensageria recebe os eventos do backend. PENDENTE: vem da configuração do microsserviço."
  type        = number
  default     = null

  validation {
    condition     = var.messaging_port == null || try(var.messaging_port >= 1 && var.messaging_port <= 65535 && floor(var.messaging_port) == var.messaging_port, false)
    error_message = "messaging_port, quando informada, precisa ser um inteiro de 1 a 65535."
  }

  validation {
    condition     = var.service_replicas.messaging == 0 || var.messaging_port != null
    error_message = "Com service_replicas.messaging = 1, informe messaging_port (a porta do microsserviço) ou deixe a mensageria desligada (0)."
  }
}

# --- 3.5 Banco de dados ----------------------------------------------------------

# tflint-ignore: terraform_unused_declarations # usada pelo módulo database (E4b)
variable "db_instance_class" {
  description = "Classe da instância do RDS (tamanho nano a medium, limite do laboratório)."
  type        = string
  default     = "db.t3.micro"
  nullable    = false

  validation {
    condition     = can(regex("^db\\.[a-z0-9-]+\\.(nano|micro|small|medium)$", var.db_instance_class))
    error_message = "db_instance_class inválida: o tamanho máximo é medium (nano, micro, small ou medium; por exemplo db.t3.micro)."
  }
}

# tflint-ignore: terraform_unused_declarations # usada pelo módulo database (E4b)
variable "db_allocated_storage_gb" {
  description = "Armazenamento do RDS, em GB."
  type        = number
  default     = 20
  nullable    = false

  validation {
    condition     = var.db_allocated_storage_gb >= 20 && var.db_allocated_storage_gb <= 100 && floor(var.db_allocated_storage_gb) == var.db_allocated_storage_gb
    error_message = "db_allocated_storage_gb precisa ser um inteiro de 20 a 100 (máximo 100)."
  }
}

# tflint-ignore: terraform_unused_declarations # usada pelo módulo database (E4b)
variable "db_multi_az" {
  description = "RDS Multi-AZ; true só se o laboratório permitir (02, seção 10)."
  type        = bool
  default     = false
  nullable    = false
}

# tflint-ignore: terraform_unused_declarations # usada pelo módulo database (E4b)
variable "db_engine_version" {
  description = "Versão principal do MySQL."
  type        = string
  default     = "8.0"
  nullable    = false

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+$", var.db_engine_version))
    error_message = "db_engine_version deve ser a versão principal do MySQL no formato X.Y (por exemplo 8.0)."
  }
}

variable "db_name" {
  description = "Nome do schema do banco; ignorado ao restaurar de snapshot."
  type        = string
  default     = "tem_na_festa"
  nullable    = false

  validation {
    condition     = can(regex("^[A-Za-z][A-Za-z0-9_]{0,63}$", var.db_name))
    error_message = "db_name deve começar com letra e ter só letras, números e _ (até 64 caracteres)."
  }
}

# tflint-ignore: terraform_unused_declarations # usada pelo módulo database (E4b)
variable "db_master_username" {
  description = "Usuário administrador do RDS; a senha é gerada (05, A1)."
  type        = string
  default     = "tnf_admin"
  nullable    = false

  validation {
    condition     = can(regex("^[A-Za-z][A-Za-z0-9_]{0,15}$", var.db_master_username))
    error_message = "db_master_username deve começar com letra e ter só letras, números e _ (até 16 caracteres, limite do RDS MySQL)."
  }
}

variable "db_snapshot_identifier" {
  description = "Snapshot de origem do RDS. Só vale na criação; o infra up o preenche apenas em ambiente novo."
  type        = string
  default     = null

  validation {
    condition     = var.db_snapshot_identifier == null || try(length(var.db_snapshot_identifier) > 0, false)
    error_message = "db_snapshot_identifier deve ser null ou o nome de um snapshot."
  }
}

variable "db_schema_repo_url" {
  description = "URL do repositório público com o script SQL do schema (TEM-NA-FESTA-database). Exigida só quando o banco nasce vazio."
  type        = string
  nullable    = false

  validation {
    condition     = var.db_snapshot_identifier != null || var.db_schema_repo_url != ""
    error_message = "Preencha db_schema_repo_url em envs/${var.env}/terraform.tfvars (URL do repositório público do schema); ela é exigida quando o banco nasce vazio, sem db_snapshot_identifier."
  }

  validation {
    condition     = var.db_schema_repo_url == "" || can(regex("^https://[^\\s]+$", var.db_schema_repo_url))
    error_message = "db_schema_repo_url deve ser uma URL https:// do repositório público do schema."
  }
}

variable "db_schema_ref" {
  description = "Tag ou commit do repositório do schema; nomes de branch são recusados. Exigida só quando o banco nasce vazio."
  type        = string
  nullable    = false

  validation {
    condition     = var.db_snapshot_identifier != null || var.db_schema_ref != ""
    error_message = "Preencha db_schema_ref em envs/${var.env}/terraform.tfvars (tag ou commit do repositório do schema); ela é exigida quando o banco nasce vazio, sem db_snapshot_identifier."
  }

  validation {
    condition     = !contains(["main", "master", "develop", "head"], lower(var.db_schema_ref))
    error_message = "db_schema_ref = \"${var.db_schema_ref}\" é uma branch: informe uma tag ou um commit, não uma branch, para o schema ser reproduzível."
  }
}

variable "db_schema_path" {
  description = "Caminho do arquivo SQL dentro do repositório do schema. Exigida só quando o banco nasce vazio."
  type        = string
  nullable    = false

  validation {
    condition     = var.db_snapshot_identifier != null || var.db_schema_path != ""
    error_message = "Preencha db_schema_path em envs/${var.env}/terraform.tfvars (caminho do script SQL no repositório do schema); ela é exigida quando o banco nasce vazio, sem db_snapshot_identifier."
  }

  validation {
    condition     = var.db_schema_path == "" || can(regex("^[^/\\s][^\\s]*$", var.db_schema_path))
    error_message = "db_schema_path deve ser um caminho relativo dentro do repositório, sem espaços e sem / no começo (por exemplo schema/init.sql)."
  }
}

# --- 3.6 Acesso e dados compartilhados -------------------------------------------

# tflint-ignore: terraform_unused_declarations # usada pelo módulo security (E3)
variable "admin_ssh_cidrs" {
  description = "CIDRs IPv4 autorizados a fazer SSH no bastion. Vazia: o infra detecta o IP atual a cada operação."
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition     = alltrue([for c in var.admin_ssh_cidrs : can(cidrnetmask(c))])
    error_message = "admin_ssh_cidrs aceita só blocos IPv4 no formato CIDR (por exemplo 203.0.113.10/32)."
  }

  validation {
    condition     = alltrue([for c in var.admin_ssh_cidrs : !endswith(c, "/0")])
    error_message = "admin_ssh_cidrs não pode conter 0.0.0.0/0: SSH aberto para o mundo é proibido. Use o seu IP com /32."
  }
}

variable "ssh_private_key_path" {
  description = "Onde gravar a chave SSH privada gerada. Se null, ./.keys/<env>.pem."
  type        = string
  default     = null

  validation {
    condition     = var.ssh_private_key_path == null || try(length(var.ssh_private_key_path) > 0, false)
    error_message = "ssh_private_key_path deve ser null ou um caminho de arquivo."
  }
}

# tflint-ignore: terraform_unused_declarations # usada pelos módulos compute e artifacts (E4a)
variable "bronze_bucket_name" {
  description = "Bucket bronze. Se null, bucket-bronze-<id-da-conta>-<bronze_bucket_region>."
  type        = string
  default     = null

  validation {
    condition     = var.bronze_bucket_name == null || can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.bronze_bucket_name))
    error_message = "bronze_bucket_name deve ser null ou um nome de bucket válido (3 a 63 caracteres: minúsculas, números, . e -)."
  }
}

# tflint-ignore: terraform_unused_declarations # usada pelos módulos compute e artifacts (E4a)
variable "bronze_bucket_region" {
  description = "Região do bucket bronze (pode diferir de region)."
  type        = string
  default     = "us-east-1"
  nullable    = false

  validation {
    condition     = can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]$", var.bronze_bucket_region))
    error_message = "bronze_bucket_region deve ser um nome de região da AWS (por exemplo us-east-1)."
  }
}

# --- 3.7 Segredos manuais --------------------------------------------------------

# tflint-ignore: terraform_unused_declarations # usada pelo módulo secrets (E4a), com a mensageria ligada
variable "messaging_secrets" {
  description = "Segredos manuais do microsserviço (vindos do secrets.env). Chaves PENDENTES; só exigidos com a mensageria ligada."
  type        = map(string)
  default     = {}
  nullable    = false
  sensitive   = true
}
