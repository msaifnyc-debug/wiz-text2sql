# EKS cluster. Nodes/pods run in PRIVATE subnets (requirement); the API endpoint is
# public for demo kubectl convenience. All control-plane log types are enabled
# (requirement: control-plane audit logging).
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.8"

  cluster_name    = "${local.name}-eks"
  cluster_version = var.cluster_version

  cluster_endpoint_public_access           = true
  enable_cluster_creator_admin_permissions = true

  # Give the GitHub Actions deploy role Kubernetes admin via an EKS access entry.
  # IAM AdministratorAccess does NOT grant in-cluster RBAC, so without this the
  # app pipeline's `kubectl apply` is Unauthorized whenever Terraform was applied
  # by a different identity (e.g. the local quickstart) than the pipeline role.
  access_entries = var.create_github_oidc ? {
    gha_deploy = {
      principal_arn = aws_iam_role.gha_deploy[0].arn
      policy_associations = {
        admin = {
          # EKS cluster access policies live in the `eks` service namespace, not
          # `iam` -- an arn:aws:iam::aws:policy/... value is rejected at apply time
          # with InvalidParameterException. Verified via `aws eks list-access-policies`.
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  } : {}

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
