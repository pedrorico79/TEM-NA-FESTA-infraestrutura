terraform {
  # Referência entre variáveis nas validações exige 1.9 ou superior; o contrato exige 1.11 (03, seção 3.8; 08, seção 4.1).
  required_version = ">= 1.11, < 2.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
