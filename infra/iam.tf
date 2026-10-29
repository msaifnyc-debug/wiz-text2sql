# ---- Mongo VM instance role --------------------------------------------------
data "aws_iam_policy_document" "vm_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "vm" {
  name               = "${local.name}-mongo-vm-role"
  assume_role_policy = data.aws_iam_policy_document.vm_assume.json
}

# ============================================================================
# INTENTIONAL WEAKNESS (required): the VM gets admin on the whole account via its
# instance profile ("overly permissive CSP permissions, e.g. able to create VMs").
# Combined with public SSH, a foothold on this box = account takeover.
#
# Detected by: CloudTrail + GuardDuty on anomalous API use; flagged pre-deploy by
# tfsec/checkov (wildcard/admin policy on an instance role).
# ============================================================================
resource "aws_iam_role_policy_attachment" "vm_admin" {
  role       = aws_iam_role.vm.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_instance_profile" "vm" {
  name = "${local.name}-mongo-vm-profile"
  role = aws_iam_role.vm.name
}

# ---- GitHub Actions OIDC deploy role (keyless CI) ----------------------------
# Lets the pipelines assume a role via OIDC instead of long-lived AWS keys.
resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
  ]
}

data "aws_iam_policy_document" "gha_assume" {
  count = var.create_github_oidc ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github[0].arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    # Scope the trust to THIS repo only.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_owner}/${var.github_repo}:*"]
    }
  }
}

resource "aws_iam_role" "gha_deploy" {
  count = var.create_github_oidc ? 1 : 0

  name               = "${local.name}-gha-deploy"
  assume_role_policy = data.aws_iam_policy_document.gha_assume[0].json
}

# Broad for the sandbox exercise (Terraform touches many services). In a real org
# this would be scoped to exactly the services/resources the pipeline manages.
resource "aws_iam_role_policy_attachment" "gha_admin" {
  count = var.create_github_oidc ? 1 : 0

  role       = aws_iam_role.gha_deploy[0].name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}
