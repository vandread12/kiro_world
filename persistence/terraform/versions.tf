terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }

  # Backend remoto: descomentar y ajustar antes del primer apply en un entorno
  # compartido. Un state local en un proyecto multi-entorno acaba en apply
  # concurrentes que se pisan.
  #
  # backend "s3" {
  #   bucket         = "pixelft-tfstate"
  #   key            = "persistence/terraform.tfstate"
  #   region         = "eu-west-1"
  #   dynamodb_table = "pixelft-tflock"
  #   encrypt        = true
  # }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "pixelft"
      Module      = "persistence"
      Environment = var.environment
      ManagedBy   = "terraform"
      CostCenter  = "game-backend"
    }
  }
}
