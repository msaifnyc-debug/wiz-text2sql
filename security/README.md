# Security controls and how I test them

Four layers. The application and pipeline rows run automatically on every PR. The
cloud and Kubernetes rows are exercised by hand against the live environment --
the commands are short enough to run from the terminal and are listed inline
below.

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

## Cloud layer — exercised by hand

| Weakness | What it proves | What catches it |
|---|---|---|
| Public backup bucket | anyone can list and download DB dumps with no AWS account | CloudTrail S3 **data** events (bucket only -- not in console Event history); Config `s3-bucket-public-read-prohibited`; GuardDuty `BucketAnonymousAccessGranted` (sev 8.0) |
| SSH open to `0.0.0.0/0` | the port is reachable from anywhere; key-only auth means guessing fails | GuardDuty `SSHBruteForce` -- **5 unsolicited findings from real hosts**; Config `restricted-ssh` |
| IMDSv1 + `AdministratorAccess` instance role | a foothold on the VM becomes account takeover, and the MongoDB **root** password sits in a world-readable file and in the user-data | CloudTrail (the stolen role's calls carry the instance ID as the user name); Config `ec2-imdsv2-check` |
| ServiceAccount bound to `cluster-admin` | one internet-facing pod reads every Secret cluster-wide and can borrow another pod's IRSA role | EKS control-plane audit logs; Kyverno `disallow-cluster-admin-serviceaccounts` (audit) |

Caught by no scanner: the MongoDB root password. In the repo it is the expression
`random_password.mongo_admin.result`; Terraform resolves it at apply time and
writes the literal value onto the host, so it exists only in the running
environment. Found by hand.

## Kubernetes layer — preventative

| What I test | Expected | Control |
|---|---|---|
| Deploy a privileged or root pod | denied at admission | Kyverno `disallow-privileged-and-root` |
| Deploy a non-ECR image into `text2sql` | denied at admission | Kyverno `restrict-image-registries` |
| The real app pod | admitted | passes both policies |
| A ServiceAccount bound to `cluster-admin` | reported, not blocked | Kyverno `disallow-cluster-admin-serviceaccounts` (**audit**, because the exercise requires the binding) |

One command exercises the first two:

```bash
kubectl -n text2sql run evil --image=nginx:latest --privileged   # denied
kubectl get cpolr | awk 'NR==1 || $5>0'                          # 1 fail: the binding
```

## Notes on timing

The cloud controls are slow -- GuardDuty takes 10-15 minutes, Config a few, and
CloudTrail data events lag 5-15 minutes before they are delivered. Kyverno is the
only control fast enough to demonstrate truly live; everything else is better
shown as an aged finding alongside the action that produced it.
