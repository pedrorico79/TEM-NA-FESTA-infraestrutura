terraform {
  required_version = ">= 1.11, < 2.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Camada persistente de dados analíticos (10, DA5). O state fica no bucket de
  # state, como o do bootstrap; o bucket e a região chegam com -backend-config.
  backend "s3" {
    key          = "analytics/terraform.tfstate"
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = local.tags
  }
}
