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
  region                      = var.aws_region
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation  = true
  skip_metadata_api_check     = true
  s3_use_path_style           = true

  endpoints {
    ec2 = "http://localhost:4566"
    rds = "http://localhost:4566"
    s3  = "http://localhost:4566"
    iam = "http://localhost:4566"
    ecr = "http://localhost:4566"
    ssm = "http://localhost:4566"
  }
}

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
