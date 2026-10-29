# Slide outline

A ~14-slide deck for a 45-minute slot: ~12 min slides, ~25 min live demo
([`DEMO_SCRIPT.md`](DEMO_SCRIPT.md)), ~8 min Q&A. Each slide lists the **point** (what's
on it) and the **say** (your spoken line). Keep slides sparse; the demo is the star.

---

### 1 — Title
- **Point:** "Text-to-SQL on AWS: a security story." Your name (Muhammed Saif), date.
- **Say:** "I deployed a real product with the required intentional weaknesses, then
  built the controls that catch each one. One story, three acts: build it, break it,
  defend it."

### 2 — The product
- **Point:** Screenshot of the app. Text-to-SQL: upload a `.db`, ask in English, get a
  read-only SELECT + results.
- **Say:** "This isn't a toy app — it's my own text-to-SQL agent. That matters later,
  because the app's own LLM/upload surface is part of the attack story."

### 3 — Architecture
- **Point:** The network diagram ([README](../README.md#architecture)). Two tiers: EKS
  (private) + MongoDB on EC2 (public), ALB ingress, public backup bucket.
- **Say:** "Two databases, two jobs: MongoDB is the app's system-of-record; the uploaded
  SQLite file is what the agent queries. The Mongo URI reaches the pod as a Kubernetes
  Secret env var."

### 4 — Act 1: it genuinely uses MongoDB + it's really on EKS
- **Point:** `mongosh` showing users/databases/history; `kubectl` image = ECR digest;
  `wizexercise.txt` → "Muhammed Saif".
- **Say:** "Live proof of the data-layer, container, and name-file requirements." → cut
  to demo Act 1.

### 5 — Intentional weaknesses (the required toxic combo)
- **Point:** Table: public-SSH VM · admin instance role · public S3 backups · outdated
  Linux + MongoDB · pod = cluster-admin.
- **Say:** "Every weakness is here on purpose, and every one is paired with a control I'll
  show detecting or preventing it."

### 6 — Act 2: the attack path
- **Point:** The attack-path graph
  ([ARCHITECTURE](ARCHITECTURE.md#attack-path-the-cnapp-graph)).
- **Say:** "Two internet entry points, each two or three hops from total compromise, both
  converging on the same world-readable bucket of DB backups." → cut to demo Act 2.

### 7 — App & LLM security (the differentiator)
- **Point:** Four upload layers (magic header · size cap · read-only `query_only` conn ·
  SELECT-only guard) + "LLM output is never trusted."
- **Say:** "I never trust the model's SQL or the uploaded file. The guard plus a
  read-only connection bound the blast radius by architecture, not by the LLM behaving."

### 8 — CI/CD: two secured pipelines
- **Point:** `infra.yml` (fmt/validate/tfsec/checkov → plan/apply) and `app.yml` (test/
  SAST/secret/image scan + SBOM → ECR → EKS). OIDC, SHA-pinned, digest deploys.
- **Say:** "Keyless auth, every Action pinned to a SHA, required status checks. Security
  is *in* the pipeline, not bolted on."

### 9 — Act 3a: shift-left caught it pre-deploy
- **Point:** `iac-scan` output flagging public bucket / open SSH / admin role; the
  enforced Gitleaks + Trivy-CRITICAL gates.
- **Say:** "The scanners found the misconfigs before anything deployed. Infra findings
  are risk-accepted for this exercise, so they're surfaced not silenced — but secrets and
  fixable critical CVEs fail the build."

### 10 — Act 3b: detective controls
- **Point:** Config NON_COMPLIANT rules · GuardDuty SSH finding · CloudTrail (+ S3 data
  events) · EKS audit logs.
- **Say:** "Audit underneath, detection on top. Config answers 'is my config compliant,'
  GuardDuty answers 'is something malicious happening.'" → show consoles.

### 11 — Act 3c: preventative control, live
- **Point:** Kyverno enforce mode denying a privileged pod and a non-ECR image; the app
  still runs.
- **Say:** "The exercise requires the cluster-admin binding to exist, so I prevent the
  *class* of risk on new workloads with admission control while leaving the weakness to
  be detected." → run `05_kyverno_prevention_demo.sh`.

### 12 — The security test matrix
- **Point:** [`TEST_MATRIX.md`](../security/TEST_MATRIX.md) thumbnail: app / pipeline /
  cloud / k8s layers; automated rows run on every PR.
- **Say:** "The 'above and beyond' without piling on surface area — each would-be attack
  mapped to the layer that stops or detects it, most of them enforced in CI."

### 13 — The closer: why a CNAPP
- **Point:** Attack-path graph again, annotated: five native signals → two prioritized
  paths.
- **Say:** "Native tools each see one dimension. 'Public bucket' is medium alone;
  'public bucket of DB dumps written by an internet-reachable admin host' is critical.
  Correlating config + identity + exposure + data sensitivity into one attack path is
  exactly what Wiz does — fix the two paths that matter, not 500 findings."

### 14 — Remediation & wrap
- **Point:** One-line fixes I can do on camera: `http_tokens=required` (IMDSv2), scope the
  VM role, block public access on the bucket, drop the cluster-admin binding.
- **Say:** "Every weakness has a one-line fix — the point was to build the detection and
  prevention around them first. Happy to remediate any of these live."

---

## Appendix slides (hold in reserve for Q&A)
- **Why Terraform over CloudFormation** ([CONCEPTS §1](CONCEPTS.md#1-infrastructure-as-code--and-why-terraform-not-cloudformation)).
- **IAM admin ≠ kubectl access** (EKS access entries) ([CONCEPTS §2](CONCEPTS.md#2-eks-irsaoidc-access-entries-and-kubernetes-rbac)).
- **SG vs NACL / gateway vs interface endpoint** ([CONCEPTS §3](CONCEPTS.md#3-networking-subnets-sg-vs-nacl-vpc-endpoints)).
- **SAST vs SCA vs IaC vs image vs secret scanning** ([CONCEPTS §5](CONCEPTS.md#5-devsecops-taxonomy-know-the-differences-cold)).
