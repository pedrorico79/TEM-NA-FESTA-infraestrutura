terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Chama o módulo reutilizável (apenas ambiente dev por enquanto)
module "tem_na_festa" {
  source = "./modules/tem-na-festa"

  aws_region                 = var.aws_region
  project_name               = var.project_name
  key_pair_name              = var.key_pair_name
  bastion_ssh_cidr           = var.bastion_ssh_cidr
  instance_type_frontend     = var.instance_type_frontend
  frontend_repository_url    = var.frontend_repository_url
  frontend_repository_branch = var.frontend_repository_branch
  instance_type_backend      = var.instance_type_backend
  instance_type_bastion      = var.instance_type_bastion
  backend_port               = var.backend_port
  backend_repository_url     = var.backend_repository_url
  backend_repository_branch  = var.backend_repository_branch
  database_repository_url    = var.database_repository_url
  database_repository_branch = var.database_repository_branch
  db_instance_class          = var.db_instance_class
  db_name                    = var.db_name
  db_master_username         = var.db_master_username
  db_master_password         = var.db_master_password
  jwt_secret                 = var.jwt_secret
  vpc_cidr                   = var.vpc_cidr
  enable_datalake            = var.enable_datalake
}
