terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
  }

  # For real use, keep state off local disk (it contains the generated DB password):
  # backend "s3" {
  #   bucket         = "your-tf-state-bucket"
  #   key            = "midnight-validator-lab/terraform.tfstate"
  #   region         = "ap-southeast-1"
  #   encrypt        = true
  #   dynamodb_table = "your-tf-locks"
  # }
}
