# Valores do ambiente prod (03). Sem segredos: os manuais ficam no secrets.env
# (05, A5), só necessário com a mensageria ligada.

env = "prod"

# Topologia (03, seção 3.2): 6 instâncias (2 web, 3 app, bastion).
az_count        = 2
nat_mode        = "per_az"
web_node_count  = 2
app_node_count  = 3
manager_count   = 3
bastion_enabled = true

# Instâncias (03, seção 3.3).
web_instance_type     = "t3.micro"
app_instance_type     = "t3.small"
bastion_instance_type = "t3.micro"

# Serviços (03, seção 3.4): mensageria desligada (0) até a E8.
service_replicas = {
  frontend  = 2
  backend   = 2
  messaging = 0
}
image_tags = {
  frontend  = "prod"
  backend   = "prod"
  messaging = "prod"
}

# Banco (03, seção 3.5).
db_instance_class = "db.t3.small"
db_multi_az       = false

# Sem valor padrão (03, seção 3.8): em branco até existirem. O plan recusa e
# diz o que preencher; precisam estar preenchidas antes da E4a.
dockerhub_namespace = ""
db_schema_repo_url  = ""
db_schema_ref       = ""
db_schema_path      = ""
