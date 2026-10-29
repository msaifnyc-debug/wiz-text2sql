data "aws_availability_zones" "available" {
  state = "available"
}

# Two-tier network: public subnets for the ALB + the (intentionally exposed) Mongo
# VM; private subnets for the EKS nodes/pods. Single NAT keeps the exercise cheap.
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.8"

  name = "${local.name}-vpc"
  cidr = var.vpc_cidr
  azs  = slice(data.aws_availability_zones.available.names, 0, 3)

  private_subnets = [for k in range(3) : cidrsubnet(var.vpc_cidr, 8, k)]
  public_subnets  = [for k in range(3) : cidrsubnet(var.vpc_cidr, 8, k + 100)]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true
  enable_dns_support   = true

  # Tags the AWS Load Balancer Controller uses for subnet auto-discovery.
  public_subnet_tags = {
    "kubernetes.io/role/elb"                  = "1"
    "kubernetes.io/cluster/${local.name}-eks" = "shared"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"         = "1"
    "kubernetes.io/cluster/${local.name}-eks" = "shared"
  }
}

# --- S3 Gateway VPC endpoint + endpoint policy --------------------------------
# Private S3 access without egressing to the internet, and a place to demonstrate
# an endpoint *policy* (not just the SG/route): scoped to the backup bucket for the
# data path, with a platform allowance so EKS/ECR layer pulls still work.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = concat(module.vpc.private_route_table_ids, module.vpc.public_route_table_ids)
  policy            = data.aws_iam_policy_document.s3_endpoint.json

  tags = { Name = "${local.name}-s3-gw-endpoint" }
}

data "aws_iam_policy_document" "s3_endpoint" {
  # Scoped access to the project's backup bucket (the data path we care about).
  statement {
    sid    = "ProjectBackupBucket"
    effect = "Allow"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"]
    resources = [
      "arn:aws:s3:::${local.backup_bucket_name}",
      "arn:aws:s3:::${local.backup_bucket_name}/*",
    ]
  }

  # Platform allowance: EKS/ECR and package mirrors read from AWS-owned S3 buckets
  # through this endpoint; without this the cluster can't pull images.
  statement {
    sid    = "PlatformReadThrough"
    effect = "Allow"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions   = ["s3:GetObject"]
    resources = ["*"]
  }
}
