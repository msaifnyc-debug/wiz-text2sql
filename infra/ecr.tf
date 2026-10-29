# Registry for the app image. Scan-on-push is a free native control that flags
# image CVEs even before Trivy runs in the pipeline.
resource "aws_ecr_repository" "app" {
  name                 = "${var.project}-app"
  image_tag_mutability = "MUTABLE" # IMMUTABLE is stronger; MUTABLE eases the demo's :latest

  image_scanning_configuration {
    scan_on_push = true
  }

  force_delete = true
  tags         = { Name = "${local.name}-app" }
}
