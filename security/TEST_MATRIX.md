# Security test matrix

The "additional test cases" that go beyond the required build. Each row is a would-be
attack or mistake, the layer that stops or detects it, and how to exercise it.
Automated rows run in CI on every PR; the rest are scripted in `attack-simulation/`.

## Application layer (automated: `cd app && pytest`)

| Test case | Expected | Control | Test |
|---|---|---|---|
| Upload a non-SQLite file renamed `.db` | Rejected | Magic-header check | `test_rejects_non_sqlite_by_magic_header` |
| Upload an empty file | Rejected | Emptiness check | `test_rejects_empty_file` |
| Upload a file over the size cap | Rejected, nothing left on disk | Streaming size cap | `test_enforces_size_cap` |
| Rejected upload cleanup | No partial file remains | Cleanup-on-failure | `test_rejected_upload_is_cleaned_up` |
| Write via the DB connection (`INSERT`/`CREATE`) | Refused | `mode=ro` + `query_only` | `test_hardened_connection_is_read_only` |
| Two users' uploads | Isolated paths | Per-user dirs | `test_per_user_isolation_paths` |
| Model/crafted-schema emits `DROP`/`DELETE`/`UPDATE`/`ALTER`/`CREATE` | Blocked | Read-only SQL guard | `test_blocks_writes_ddl_and_stacked` |
| Stacked query `SELECT 1; DROP TABLE` | Blocked | Single-statement guard | `test_blocks_writes_ddl_and_stacked` |
| `ATTACH DATABASE '/etc/passwd'` (cross-db escape) | Blocked | SELECT-only guard | `test_blocks_writes_ddl_and_stacked` |
| Unauthenticated API call | 401 | JWT session dependency | HTTP smoke (`/api/dbs`, `/api/ask`) |
| Weak/invalid signup payload | 422 | Pydantic validation | HTTP smoke |

## Pipeline layer (CI, every PR)

| Test case | Expected | Control |
|---|---|---|
| Hardcoded secret committed | Build fails | Gitleaks (enforced) + push protection |
| Fixable CRITICAL image CVE | Build fails | Trivy gate (enforced) |
| HIGH/CRITICAL image CVEs | Reported, visible | Trivy report step |
| Insecure Terraform (public bucket, open SSH, admin role) | Flagged pre-deploy | tfsec + checkov (soft-fail; see docs/OVERVIEW.md) |
| Python code smells / injection patterns | Reported | Semgrep (advisory) |
| Image provenance | `wizexercise.txt` printed from the image, then from the running pod | build + post-deploy exec |
| Unpinned action / stale dep | PR raised | SHA pins + Dependabot |

## Cloud layer (detective/preventative; `attack-simulation/`)

| Test case | Expected | Control |
|---|---|---|
| Anonymous list/download of DB backups | Succeeds (exposure), and is recorded | CloudTrail S3 data events; Config `s3-bucket-public-read-prohibited` NON_COMPLIANT |
| SSH brute force on the VM | Detected | GuardDuty `SSHBruteForce`; Config `restricted-ssh` |
| IMDSv1 role-credential theft on the VM | Works (weakness), fully logged | CloudTrail; Config `ec2-imdsv2-check`; GuardDuty on anomalous use |
| Public IP / admin instance profile present | Flagged | Config + GuardDuty |

## Kubernetes layer (preventative; `05_kyverno_prevention_demo.sh`)

| Test case | Expected | Control |
|---|---|---|
| Deploy a privileged / root pod | Denied at admission | Kyverno `disallow-privileged-and-root` |
| Deploy a non-ECR public image into `text2sql` | Denied at admission | Kyverno `restrict-image-registries` |
| The real app pod (non-root, ECR image) | Admitted | passes both policies |
