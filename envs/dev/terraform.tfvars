# Valores do ambiente dev (03). Sem segredos: os manuais ficam no secrets.env
# (05, A5), só necessário com a mensageria ligada.

env = "dev"

# Topologia (03, seção 3.2): 3 instâncias (1 web, 1 app, bastion).
az_count        = 1
nat_mode        = "single"
web_node_count  = 1
app_node_count  = 1
manager_count   = 1
bastion_enabled = true

# Instâncias (03, seção 3.3).
web_instance_type     = "t3.micro"
app_instance_type     = "t3.medium" # E8: backend, RabbitMQ e mensageria no app-1 (06, seção 8)
bastion_instance_type = "t3.micro"

# Serviços (03, seção 3.4): mensageria desligada (0) até a E8.
service_replicas = {
  frontend  = 1
  backend   = 1
  messaging = 1
}
image_tags = {
  frontend  = "dev"
  backend   = "dev"
  messaging = "dev"
}

# Banco (03, seção 3.5).
db_instance_class = "db.t3.micro"
db_multi_az       = false

# Sem valor padrão (03, seção 3.8), preenchidas na E4a: usuário do Docker Hub
# e a origem do script do schema (tag do TEM-NA-FESTA-database, 05 B5).
dockerhub_namespace = "cesaraugustotech"
db_schema_repo_url  = "https://github.com/pedrorico79/TEM-NA-FESTA-database"
db_schema_ref       = "v1.0.0"
db_schema_path      = "script-bd-tem-na-festa.sql"

# Mensageria ligada (E8): porta do microsserviço e o banco dele, um segundo
# schema no mesmo RDS. O token da Whapi fica no secrets.env (infra init-secrets).
messaging_port               = 8081
messaging_db_schema_repo_url = "https://github.com/pedrorico79/TEM-NA-FESTA-microservice"
messaging_db_schema_ref      = "v1.0.0"
messaging_db_schema_path     = "src/main/resources/db/migration/V1__create_initial_schema.sql"
