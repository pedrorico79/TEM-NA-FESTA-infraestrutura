terraform {
  required_version = ">= 1.11, < 2.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # O state do bootstrap fica no próprio bucket de state (08, seção 5; H4).
  # O bucket e a região chegam pelo infra bootstrap com -backend-config. Na
  # primeira execução, antes de o bucket existir, o infra usa um
  # backend_override.tf temporário com state local e depois migra.
  backend "s3" {
    key          = "bootstrap/terraform.tfstate"
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = local.tags
  }
}

# O bucket bronze pode ficar em outra região (03, seção 3.6).
provider "aws" {
  alias  = "bronze"
  region = var.bronze_bucket_region

  default_tags {
    tags = local.tags
  }
}
