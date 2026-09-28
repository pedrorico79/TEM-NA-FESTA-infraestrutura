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

data "terraform_remote_state" "storage" {
  backend = "local"
  config = {
    path = "../data-storage/terraform.tfstate"
  }
}

module "compute" {
  source = "../../../modules/compute"

  aws_region                 = var.aws_region
  project_name               = var.project_name
  vpc_id                     = data.terraform_remote_state.network.outputs.vpc_id
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
  public_bastion_subnet_id   = data.terraform_remote_state.network.outputs.public_bastion_subnet_id
  public_alb_subnet_id       = data.terraform_remote_state.network.outputs.public_alb_subnet_id
  private_frontend_subnet_ids = data.terraform_remote_state.network.outputs.private_frontend_subnet_ids
  private_backend_subnet_ids  = data.terraform_remote_state.network.outputs.private_backend_subnet_ids
  efs_id                     = data.terraform_remote_state.storage.outputs.efs_id
}

output "website_url" {
  value = module.compute.website_url
}

output "bastion_public_ip" {
  value = module.compute.bastion_public_ip
}
