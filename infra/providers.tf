terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = local.tags
  }

  # The CloudLabs lab platform tags every resource with "aws-apn-id" for partner
  # billing attribution. That tag is not declared here, so Terraform proposes
  # removing it on every plan -- and the platform re-adds it, producing permanent
  # drift that has nothing to do with this configuration. Ignore it so `plan`
  # reflects real differences only.
  ignore_tags {
    keys = ["aws-apn-id"]
  }
}
