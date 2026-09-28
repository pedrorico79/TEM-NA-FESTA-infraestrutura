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

module "network" {
  source = "../../../modules/network"

  aws_region   = var.aws_region
  project_name = var.project_name
  vpc_cidr     = var.vpc_cidr
}

output "vpc_id" {
  value = module.network.vpc_id
}

output "public_bastion_subnet_id" {
  value = module.network.public_bastion_subnet_id
}

output "public_alb_subnet_id" {
  value = module.network.public_alb_subnet_id
}

output "private_frontend_subnet_ids" {
  value = module.network.private_frontend_subnet_ids
}

output "private_backend_subnet_ids" {
  value = module.network.private_backend_subnet_ids
}

output "private_db_subnet_ids" {
  value = module.network.private_db_subnet_ids
}

output "rds_security_group_id" {
  value = module.network.rds_security_group_id
}

output "efs_security_group_id" {
  value = module.network.efs_security_group_id
}

