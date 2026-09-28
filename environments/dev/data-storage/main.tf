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

# A camada de storage depende dos outputs da camada de network
data "terraform_remote_state" "network" {
  backend = "local"
  config = {
    path = "../network/terraform.tfstate"
  }
}

module "data_storage" {
  source = "../../../modules/data-storage"

  project_name               = var.project_name
  db_instance_class           = var.db_instance_class
  db_name                    = var.db_name
  db_master_username          = var.db_master_username
  db_master_password         = var.db_master_password
  private_db_subnet_ids      = data.terraform_remote_state.network.outputs.private_db_subnet_ids
  private_frontend_subnet_ids = data.terraform_remote_state.network.outputs.private_frontend_subnet_ids
  
  rds_security_group_id = data.terraform_remote_state.network.outputs.rds_security_group_id
  efs_security_group_id = data.terraform_remote_state.network.outputs.efs_security_group_id
}

output "rds_endpoint" {
  value = module.data_storage.rds_endpoint
}

output "efs_id" {
  value = module.data_storage.efs_id
}
