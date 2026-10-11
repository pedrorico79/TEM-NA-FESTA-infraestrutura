terraform {
  required_version = ">= 1.11, < 2.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = var.region == null ? "us-east-1" : var.region

  # Etiquetas de todos os recursos (08, seção 4.1). O infra doctor usa
  # ManagedBy e Project para separar as sobras da infraestrutura antiga.
  default_tags {
    tags = {
      Project   = "tem-na-festa"
      Env       = var.env
      ManagedBy = "terraform"
    }
  }
}
