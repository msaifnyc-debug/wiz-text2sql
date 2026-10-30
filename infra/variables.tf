variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Short name used to prefix resources."
  type        = string
  default     = "text2sql"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.20.0.0/16"
}

variable "cluster_version" {
  description = "EKS Kubernetes version."
  type        = string
  default     = "1.33"
}

variable "node_instance_type" {
  description = "EKS managed node group instance type."
  type        = string
  default     = "t3.medium"
}

# --- Intentional-weakness knobs (defaults reproduce the exercise's weaknesses) --
variable "ssh_ingress_cidr" {
  description = "CIDR allowed to SSH the Mongo VM. INTENTIONALLY open for the exercise."
  type        = string
  default     = "0.0.0.0/0"
}

variable "mongodb_version" {
  description = "MongoDB major version (INTENTIONALLY 1+ year outdated / EOL)."
  type        = string
  default     = "5.0"
}

variable "vm_ssh_public_key" {
  description = "Optional SSH public key material for the Mongo VM key pair. Empty = no key pair."
  type        = string
  default     = ""
}

# --- CI/CD OIDC (GitHub Actions) -----------------------------------------------
variable "github_owner" {
  description = "GitHub org/user that owns the repo (for the Actions OIDC trust)."
  type        = string
  default     = ""
}

variable "github_repo" {
  description = "GitHub repository name (for the Actions OIDC trust)."
  type        = string
  default     = ""
}

variable "create_github_oidc" {
  description = "Create the GitHub Actions OIDC provider + deploy role."
  type        = bool
  default     = true
}

# Numeric GitHub owner/repository IDs, used to match GitHub's immutable OIDC
# subject claim (repo:<owner>@<owner_id>/<repo>@<repo_id>:...). Look them up with:
#   gh api repos/<owner>/<repo> --jq '{repo_id:.id, owner_id:.owner.id}'
# Leave empty to trust only the legacy name-only subject shape.
variable "github_owner_id" {
  description = "Numeric GitHub owner (user/org) ID for the immutable OIDC subject claim."
  type        = string
  default     = ""
}

variable "github_repository_id" {
  description = "Numeric GitHub repository ID for the immutable OIDC subject claim."
  type        = string
  default     = ""
}
