terraform {
  required_version = ">= 1.11, < 2.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Bucket, região e chave (e3/<env>/terraform.tfstate) chegam pelo infra.
  backend "s3" {
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "tem-na-festa"
      Env       = var.env
      ManagedBy = "terraform"
    }
  }
}
