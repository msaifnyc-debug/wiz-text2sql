# Attack simulation -> control mapping

Run these against your deployed environment to show the controls firing. Each maps
to a preventative or detective control, which is the core Act 3 narrative.

| # | Attack script | What it proves | Control that catches it |
|---|---|---|---|
| 01 | `01_public_bucket_access.sh <bucket>` | Anyone can list + download DB dumps with no AWS account | CloudTrail S3 data events (detective); AWS Config `s3-bucket-public-read-prohibited` = NON_COMPLIANT |
| 02 | `02_ssh_bruteforce.sh <vm-ip>` | SSH is open to the internet | GuardDuty `UnauthorizedAccess:EC2/SSHBruteForce` (detective); Config `restricted-ssh` |
| 03 | `03_imds_role_theft.sh` (on the VM) | IMDSv1 + admin instance role = account takeover | CloudTrail (all API calls); GuardDuty on anomalous role use; Config `ec2-imdsv2-check` |
| 04 | `04_pod_cluster_admin.sh` (in the pod) | One internet-facing pod can read every secret and act cluster-wide | EKS control-plane audit logs (detective) |
| 05 | `05_kyverno_prevention_demo.sh` | Bad workloads are stopped before they run | Kyverno admission policies (PREVENTATIVE) - both attempts denied |

## Suggested demo order
1. Run **05** first to show prevention working (Kyverno denies the bad pods; the app
   itself keeps running).
2. Run **01** to show the public bucket exposure, then open AWS Config and show the
   bucket marked NON_COMPLIANT.
3. Run **02**, then show the GuardDuty finding a few minutes later.
4. SSH in and run **03**, then **04** from the pod, to walk the full attack path.
5. Close on the CNAPP view: this is one correlated attack path, not five separate
   findings.
