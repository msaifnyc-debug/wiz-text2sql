# Mongo credentials (kept in state/outputs; wired into the K8s Secret).
resource "random_password" "mongo_admin" {
  length  = 20
  special = false
}

resource "random_password" "mongo_app" {
  length  = 20
  special = false
}

# INTENTIONAL WEAKNESS (required): a 1+ year outdated Linux. Ubuntu 20.04 "focal"
# is past its standard-support window and will light up host/CVE scanners.
data "aws_ami" "ubuntu_focal" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-focal-20.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_key_pair" "vm" {
  count      = var.vm_ssh_public_key == "" ? 0 : 1
  key_name   = "${local.name}-mongo-vm"
  public_key = var.vm_ssh_public_key
}

resource "aws_security_group" "mongo_vm" {
  name_prefix = "${local.name}-mongo-vm-"
  description = "Mongo VM: public SSH (intentional) + Mongo reachable from EKS only"
  vpc_id      = module.vpc.vpc_id

  # INTENTIONAL WEAKNESS (required): SSH open to the entire internet.
  ingress {
    description = "public SSH (intentional weakness)"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_ingress_cidr]
  }

  # Requirement: database access restricted to the Kubernetes network only.
  ingress {
    description     = "MongoDB from EKS nodes only"
    from_port       = 27017
    to_port         = 27017
    protocol        = "tcp"
    security_groups = [module.eks.node_security_group_id]
  }

  egress {
    description = "all egress"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name}-mongo-vm" }
}

resource "aws_instance" "mongo" {
  ami                         = data.aws_ami.ubuntu_focal.id
  instance_type               = "t3.small"
  subnet_id                   = module.vpc.public_subnets[0]
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.mongo_vm.id]
  iam_instance_profile        = aws_iam_instance_profile.vm.name
  key_name                    = var.vm_ssh_public_key == "" ? null : aws_key_pair.vm[0].key_name

  # INTENTIONAL WEAKNESS: IMDSv1 left enabled. An SSRF in the app or a foothold on
  # the box can read the instance role creds from the metadata service -> uses the
  # admin profile above. (Set http_tokens="required" to remediate on camera.)
  metadata_options {
    http_tokens   = "optional"
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_size = 20
    encrypted   = true
  }

  user_data = templatefile("${path.module}/user_data.sh.tpl", {
    mongodb_version = var.mongodb_version
    admin_password  = random_password.mongo_admin.result
    app_password    = random_password.mongo_app.result
    app_db          = var.project
    region          = var.region
    backup_bucket   = aws_s3_bucket.backups.bucket
  })

  tags = { Name = "${local.name}-mongo" }
}
