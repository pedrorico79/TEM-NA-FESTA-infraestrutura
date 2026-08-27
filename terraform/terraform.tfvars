# Preencha os valores abaixo antes do "terraform apply".
# NUNCA commite este arquivo com segredos reais — adicione ao .gitignore:
#   echo "terraform.tfvars" >> .gitignore

aws_region       = "us-east-1"
project_name     = "tem-na-festa"
key_pair_name    = "minha-keypair"       # Key Pair já existente na conta AWS
bastion_ssh_cidr = "203.0.113.10/32"     # Restrinja ao seu IP em produção

db_master_username = "admin"
db_master_password = "TrocarEstaSenha123!" # Mínimo 8 caracteres
