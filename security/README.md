# Security controls and how I test them

Four layers. The application and pipeline rows run automatically on every PR; the
cloud and Kubernetes rows are exercised by the scripts in `attack-simulation/`.

## Application layer — runs in CI (`cd app && pytest`)

| What I test | Expected | Control |
|---|---|---|
| Non-SQLite file renamed `.db` | rejected | magic-header check |
| Empty file | rejected | emptiness check |
| File over the size cap | rejected, nothing left on disk | streaming size cap |
| A rejected upload | no partial file remains | cleanup on failure |
| `INSERT`/`CREATE` through the DB connection | refused | `mode=ro` + `query_only` |
| Two users' uploads | isolated paths | per-user directories |
| Model emits `DROP`/`DELETE`/`UPDATE`/`ALTER` | blocked | read-only SQL guard |
| Stacked query `SELECT 1; DROP TABLE` | blocked | single-statement guard |
| `ATTACH DATABASE '/etc/passwd'` | blocked | SELECT-only guard |

## Pipeline layer — runs in CI on every PR

| What I test | Expected | Control |
|---|---|---|
| A hardcoded secret is committed | build fails | Gitleaks (enforced) + push protection |
| A fixable CRITICAL image CVE | build fails | Trivy gate (enforced) — this has fired |
| HIGH/CRITICAL image CVEs | reported, visible | Trivy report step |
| Insecure Terraform | flagged pre-deploy, 41 alerts | tfsec + checkov (report-only, see `docs/OVERVIEW.md`) |
| Insecure Python patterns | reported | Semgrep (advisory) |
| Image provenance | `wizexercise.txt` read from the image, then from the running pod | build + post-deploy exec |
| A stale dependency or unpinned action | a PR is raised | SHA pins + Dependabot |

## Cloud layer — `attack-simulation/`

| # | Script | What it proves | What catches it |
|---|---|---|---|
| 01 | `01_public_bucket_access.sh` | anyone can list and download DB dumps with no AWS account | CloudTrail S3 data events; Config `s3-bucket-public-read-prohibited` |
| 02 | `02_ssh_bruteforce.sh` | SSH is open to the internet | GuardDuty `SSHBruteForce`; Config `restricted-ssh` |
| 03 | `03_imds_role_theft.sh` *(run on the VM)* | IMDSv1 + admin instance role = account takeover | CloudTrail; Config `ec2-imdsv2-check`; GuardDuty |
| 04 | `04_pod_cluster_admin.sh` *(run in the pod)* | one internet-facing pod reads every secret cluster-wide | EKS control-plane audit logs |

## Kubernetes layer — preventative

| What I test | Expected | Control |
|---|---|---|
| Deploy a privileged or root pod | denied at admission | Kyverno `disallow-privileged-and-root` |
| Deploy a non-ECR image into `text2sql` | denied at admission | Kyverno `restrict-image-registries` |
| The real app pod | admitted | passes both policies |

Exercise all three with `05_kyverno_prevention_demo.sh`.

## Demo order

The cloud controls are slow — GuardDuty takes 10-15 minutes and Config a few — so I
run 01 through 04 about an hour before presenting and point at the aged findings.

1. **05 first.** Kyverno denies the bad pods instantly while the app keeps running.
   It is the only control fast enough to demo truly live.
2. **01**, then open AWS Config and show the bucket NON_COMPLIANT.
3. **02**, then the GuardDuty finding.
4. SSH in for **03**, then **04** from inside the pod, to walk the full path.
5. Close on the correlation: one attack path, not five separate findings.
