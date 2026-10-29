# ============================================================================
# INTENTIONAL WEAKNESS (required by the exercise):
# A public-READABLE and public-LISTABLE bucket that stores daily MongoDB backups.
# Anyone on the internet can list and download the database dumps.
#
# Detected by: AWS Config `s3-bucket-public-read-prohibited` (see config.tf),
# flagged pre-deploy by tfsec/checkov in the IaC pipeline.
# ============================================================================
resource "aws_s3_bucket" "backups" {
  bucket        = local.backup_bucket_name
  force_destroy = true
  tags          = { Name = "${local.name}-mongo-backups" }
}

# Disable the account/bucket "block public access" guardrails so the public policy
# below can actually take effect. (This is the weakness.)
resource "aws_s3_bucket_public_access_block" "backups" {
  bucket                  = aws_s3_bucket.backups.id
  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_ownership_controls" "backups" {
  bucket = aws_s3_bucket.backups.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "backups" {
  bucket = aws_s3_bucket.backups.id
  versioning_configuration {
    status = "Enabled"
  }
}

data "aws_iam_policy_document" "backups_public" {
  statement {
    sid    = "PublicReadAndListIntentional"
    effect = "Allow"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions = ["s3:GetObject", "s3:ListBucket"]
    resources = [
      aws_s3_bucket.backups.arn,
      "${aws_s3_bucket.backups.arn}/*",
    ]
  }
}

resource "aws_s3_bucket_policy" "backups_public" {
  bucket = aws_s3_bucket.backups.id
  policy = data.aws_iam_policy_document.backups_public.json

  # The policy can only be public once the access block is lifted.
  depends_on = [aws_s3_bucket_public_access_block.backups]
}
