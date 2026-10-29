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
  default     = "1.29"
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
