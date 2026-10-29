output "region" {
  value = var.region
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "configure_kubectl" {
  description = "Run this to talk to the cluster."
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region}"
}

output "ecr_repository_url" {
  value = aws_ecr_repository.app.repository_url
}

output "mongo_vm_public_ip" {
  value = aws_instance.mongo.public_ip
}

output "mongo_vm_private_ip" {
  value = aws_instance.mongo.private_ip
}

output "backup_bucket" {
  value = aws_s3_bucket.backups.bucket
}

output "backup_bucket_public_url" {
  description = "Public listing URL (intentional weakness) to show in the demo."
  value       = "https://${aws_s3_bucket.backups.bucket}.s3.${var.region}.amazonaws.com/"
}

output "lb_controller_role_arn" {
  value = module.lb_controller_irsa.iam_role_arn
}

output "gha_deploy_role_arn" {
  description = "Set as the AWS_ROLE_ARN repo variable for the pipelines."
  value       = var.create_github_oidc ? aws_iam_role.gha_deploy[0].arn : null
}

# The connection string the K8s Secret needs. Sensitive: contains the app password.
output "mongodb_uri" {
  description = "Wire into the K8s Secret as MONGODB_URI (see k8s/secret.example.yaml)."
  value       = "mongodb://appuser:${random_password.mongo_app.result}@${aws_instance.mongo.private_ip}:27017/${var.project}?authSource=${var.project}"
  sensitive   = true
}
