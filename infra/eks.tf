# EKS cluster. Nodes/pods run in PRIVATE subnets (requirement); the API endpoint is
# public for demo kubectl convenience. All control-plane log types are enabled
# (requirement: control-plane audit logging).
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.8"

  cluster_name    = "${local.name}-eks"
  cluster_version = var.cluster_version

  cluster_endpoint_public_access = true

  # Deliberately FALSE. This option grants cluster-admin to whichever identity
  # happens to run `terraform apply`, which is non-deterministic when the same
  # state is applied both locally and by CI: each apply tried to create a
  # "cluster_creator" access entry for a different principal, and the second one
  # failed with ResourceInUseException (409). Every admin is listed explicitly
  # below instead, so the result is identical no matter who applies.
  enable_cluster_creator_admin_permissions = false

  # Kubernetes admin via EKS access entries. IAM AdministratorAccess does NOT
  # grant in-cluster RBAC, so without these `kubectl` is Unauthorized -- for the
  # app pipeline's deploy and for local operators alike.
  access_entries = merge(
    var.create_github_oidc ? {
      gha_deploy = {
        principal_arn       = aws_iam_role.gha_deploy[0].arn
        policy_associations = local.eks_cluster_admin_association
      }
    } : {},
    {
      for arn in var.cluster_admin_principal_arns :
      "admin_${md5(arn)}" => {
        principal_arn       = arn
        policy_associations = local.eks_cluster_admin_association
      }
    },
  )

  # Control-plane audit logging -> CloudWatch Logs.
  cluster_enabled_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.private_subnets

  eks_managed_node_groups = {
    default = {
      min_size       = 2
      max_size       = 3
      desired_size   = 2
      instance_types = [var.node_instance_type]
      subnet_ids     = module.vpc.private_subnets
    }
  }

  tags = local.tags
}

# IRSA role for the AWS Load Balancer Controller (installed via Helm at bootstrap;
# see infra/bootstrap-addons.sh). The controller provisions the internet-facing
# ALB from the app's Ingress.
module "lb_controller_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.39"

  role_name                              = "${local.name}-aws-lbc"
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }

  tags = local.tags
}
