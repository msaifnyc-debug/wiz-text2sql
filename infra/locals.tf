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

locals {
  # EKS cluster access policies live in the `eks` service namespace, not `iam` --
  # an arn:aws:iam::aws:policy/... value is rejected at apply time with
  # InvalidParameterException. Verified via `aws eks list-access-policies`.
  eks_cluster_admin_association = {
    admin = {
      policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
      access_scope = { type = "cluster" }
    }
  }
}
