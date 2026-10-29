data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  name = var.project

  tags = {
    Project   = var.project
    Exercise  = "wiz-technical-exercise"
    ManagedBy = "terraform"
    Warning   = "intentionally-insecure-do-not-use-in-prod"
  }

  account_id = data.aws_caller_identity.current.account_id

  # Backups bucket name must be globally unique; suffix with the account id.
  backup_bucket_name = "${var.project}-mongo-backups-${data.aws_caller_identity.current.account_id}"
}
