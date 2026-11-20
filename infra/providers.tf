terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
    datadog = {
      source  = "DataDog/datadog"
      version = "~> 3.0"
    }
  }

  # Recomendado: guardar o estado num bucket S3 separado (crie o bucket antes).
  # backend "s3" {
  #   bucket       = "SEU-BUCKET-DE-ESTADO"
  #   key          = "lakehouse-cvm/terraform.tfstate"
  #   region       = "us-east-1"
  #   use_lockfile = true
  # }
}

provider "aws" {
  region = var.regiao

  default_tags {
    tags = {
      projeto    = var.projeto
      gerenciado = "terraform"
    }
  }
}

# Chaves via variáveis de ambiente DD_API_KEY e DD_APP_KEY (nunca no código).
provider "datadog" {
  api_url  = var.datadog_api_url
  validate = var.datadog_habilitado ? "true" : "false" # permite rodar sem chaves quando desabilitado
}

data "aws_caller_identity" "atual" {}
