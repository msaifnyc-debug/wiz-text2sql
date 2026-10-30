# Shared, non-secret configuration for this exercise. Committed on purpose and
# auto-loaded by Terraform, so a local apply and a CI apply compute an identical
# plan. Previously these lived only in the gitignored terraform.tfvars, so every
# CI apply recomputed the config without them and reverted the deploy role's OIDC
# trust policy and destroyed the VM key pair.
#
# Account-specific values (e.g. cluster_admin_principal_arns, which contains an
# account ID) stay OUT of this file -- see terraform.tfvars locally and the
# CLUSTER_ADMIN_ARNS repository variable for CI.

region  = "us-east-1"
project = "text2sql"

cluster_version    = "1.33"
node_instance_type = "t3.medium"

github_owner       = "msaifnyc-debug"
github_repo        = "wiz-text2sql"
create_github_oidc = true

# Numeric IDs for GitHub's immutable OIDC subject claim.
github_owner_id      = "301498252"
github_repository_id = "1439201590"

# Public half of the demo keypair. A public key is not a secret.
vm_ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIED057+e0Xf3l7V0fFGdWZPz9jxtZOjqcm2NsGmgXB2e wiz-exercise-mongo-vm"
