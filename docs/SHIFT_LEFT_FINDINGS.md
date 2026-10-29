# Shift-left findings: what the IaC scan caught before deploy

Captured by running the same `checkov` scan the IaC pipeline runs
(`checkov -d infra --framework terraform`). Result: **142 passed, 42 failed**.

The point for the demo: **every intentional weakness was flagged before a single
resource existed.** The pipeline surfaces them pre-deploy; for this exercise they are
soft-fail because the weaknesses are required (risk explicitly accepted and
documented). In a real pipeline these same checks would be hard gates.

## Planted weakness -> the check that caught it

| Planted weakness | Checkov check(s) | Where |
|---|---|---|
| SSH open to the internet | `CKV_AWS_24` no ingress 0.0.0.0/0 to port 22 | `infra/mongo_vm.tf` |
| VM has admin on the account | `CKV_AWS_274` disallow AdministratorAccess | `infra/iam.tf` |
| Public-readable/listable backup bucket | `CKV_AWS_53`, `CKV_AWS_54`, `CKV_AWS_55`, `CKV_AWS_56`, `CKV2_AWS_6` (public access block off) | `infra/s3_backups.tf` |
| IMDSv1 left enabled on the VM | `CKV_AWS_79` IMDSv1 must not be enabled | `infra/mongo_vm.tf` |
| VM directly internet-exposed | `CKV_AWS_88` EC2 should not have a public IP | `infra/mongo_vm.tf` |
| Overly broad IAM resource scope | `CKV_AWS_356`, `CKV_AWS_108` (`"*"` resource / exfiltration) | `infra/vpc.tf`, `infra/s3_backups.tf` |

## An honest finding worth saying out loud

`CKV_TF_1` "Ensure Terraform module sources use a commit hash" fired on the three
community modules (VPC, EKS, IAM). I pinned every **GitHub Action** to a full commit
SHA, but the Terraform modules are pinned by *version*. That is the same supply-chain
risk (a compromised or re-pointed tag), just in a different layer. Next step: pin
modules to a commit SHA too. This is a good "the tool taught me something" moment.

## Hardening backlog (real findings, intentionally deferred for the exercise)

These are genuine but not part of the required weakness set; they are the "what I'd
do next" list:

- KMS CMK encryption for S3, ECR, and CloudTrail (`CKV_AWS_145`, `CKV_AWS_136`, `CKV_AWS_35`)
- Immutable ECR tags (`CKV_AWS_51`) - deploys already pin by digest
- CloudTrail -> CloudWatch Logs integration + SNS (`CKV2_AWS_10`, `CKV_AWS_252`)
- S3 access logging, lifecycle, event notifications (`CKV_AWS_18`, `CKV2_AWS_61`, `CKV2_AWS_62`)
- Restrict SG egress (`CKV_AWS_382`)

Reproduce:

```bash
pip install checkov
checkov -d infra --framework terraform --compact
```
