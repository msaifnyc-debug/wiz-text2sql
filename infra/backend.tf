# Remote state. Create the bucket + DynamoDB lock table once (out of band), then
# `terraform init`. Kept as a separate file so it is easy to find and swap.
#
# The CI pipeline passes these via `-backend-config` so no account-specific values
# live in the repo.
terraform {
  backend "s3" {
    # bucket         = "text2sql-tfstate-<account-id>"
    # key            = "wiz-exercise/terraform.tfstate"
    # region         = "us-east-1"
    # dynamodb_table = "text2sql-tf-locks"
    # encrypt        = true
  }
}
