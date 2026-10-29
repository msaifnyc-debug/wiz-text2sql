# Concepts cheat-sheet (interview prep)

Everything in this build, explained so you can speak to it confidently. Each section
is: **what it is**, **how it shows up in this project**, and **likely question → crisp
answer**. Built on top of your existing base (IAM user/role policies, bucket policies,
VPC endpoint policies).

---

## 1. Infrastructure as Code — and "why Terraform, not CloudFormation?"

**What it is.** Declarative definitions of cloud resources, version-controlled and
applied by a tool that diffs desired vs actual state. Terraform uses HCL and a
provider model; CloudFormation (CFN) uses YAML/JSON and is AWS-native.

**In this project.** Everything in `infra/` is Terraform: VPC, EKS, the Mongo VM, S3,
IAM, ECR, CloudTrail, Config, GuardDuty. State is an S3 backend with a DynamoDB lock;
community modules (`terraform-aws-modules/{vpc,eks,iam}`) do the heavy lifting.

**Why Terraform over CloudFormation here (the answer to give):**
- **Multi-cloud / portable skill.** Terraform speaks to AWS, Azure, GCP, Kubernetes,
  GitHub, and more through one workflow and language. For a security exercise meant to
  generalize (and for a CNAPP vendor whose customers are multi-cloud), that portability
  matters; CFN is AWS-only.
- **Module ecosystem.** The battle-tested `terraform-aws-modules/eks` and `/vpc` give
  me a correct, well-reviewed VPC + EKS in ~50 lines. CFN's equivalent is more verbose,
  and its reusable unit (nested stacks) is clunkier than Terraform modules.
- **`terraform plan` as a review artifact.** The plan is a precise, human-readable diff
  I can gate CI on and show in the demo. CFN change sets exist but are less ergonomic in
  a PR flow.
- **Explicit state + drift.** A readable state file plus `plan` makes drift detection
  and code review straightforward; the same tooling (tfsec/checkov) scans the HCL.
- **One tool across layers.** Same tool provisions AWS *and* the GitHub OIDC trust, so
  the whole supply chain is one codebase.

**Honest trade-offs (shows maturity).** CFN has no state file to secure or lose,
integrates natively with StackSets/Service Catalog/drift detection, and is first-class
in AWS support. For an AWS-only shop standardized on CFN, it's a fine choice — this is a
*preference for portability and ecosystem*, not CFN being wrong. (CDK/Pulumi are the
"real programming language" alternatives; I'd reach for them when I need loops/abstraction
beyond HCL.)

**Likely Q → A.**
- *"What secures your Terraform state?"* → Remote S3 backend (encrypted, versioned,
  private) with a DynamoDB lock to prevent concurrent applies; state is never committed
  and holds sensitive outputs (e.g. the Mongo password), so `mongodb_uri` is marked
  `sensitive`.

---

## 2. EKS, IRSA/OIDC, access entries, and Kubernetes RBAC

**What it is.** EKS is managed Kubernetes. Two *separate* authorization systems meet
here: **IAM** (who you are to AWS) and **Kubernetes RBAC** (what you can do in the
cluster). Bridging them is the part people get wrong.

**In this project.**
- **IRSA (IAM Roles for Service Accounts)** via the cluster's **OIDC provider**: the
  AWS Load Balancer Controller's k8s ServiceAccount assumes a *scoped* IAM role — no
  node-wide credentials. This is the least-privilege contrast to the VM's admin role.
- **EKS access entries** (the modern replacement for the `aws-auth` ConfigMap) map the
  GitHub Actions IAM role to cluster-admin so the pipeline's `kubectl` works. I added
  this explicitly because **IAM AdministratorAccess does *not* grant in-cluster RBAC** —
  a classic gotcha.
- **RBAC, intentional weakness:** the app's ServiceAccount is bound to `cluster-admin`
  (`k8s/clusterrolebinding.yaml`). That's the "container has cluster-admin" requirement.

**Likely Q → A.**
- *"IAM admin can't run kubectl?"* → Correct. IAM gets you to the EKS API; a matching
  access entry (or `aws-auth`) is what grants Kubernetes verbs. That's why `eks.tf` has
  an access entry for the pipeline role.
- *"IRSA vs instance profile?"* → IRSA scopes credentials to a pod's SA via OIDC
  federation (least privilege, short-lived). An instance profile gives *every* process
  on the node the same role — which is exactly the over-permissive VM weakness.
- *"How does traffic reach a private pod?"* → Internet → ALB in public subnets
  (provisioned by the LB Controller from the Ingress) → Service → pod in private
  subnets. Nodes never get public IPs.

---

## 3. Networking: subnets, SG vs NACL, VPC endpoints

**What it is.** A VPC split into public (route to an Internet Gateway) and private
(egress via NAT) subnets. **Security Groups** are stateful, instance-level allow-lists;
**NACLs** are stateless, subnet-level allow/deny.

**In this project.**
- Public subnets: ALB + the Mongo VM. Private subnets: EKS nodes/pods. One NAT gateway
  for private egress (keeps the exercise cheap).
- **SG design tells the story:** the VM allows **22 from `0.0.0.0/0`** (intentional
  weakness) but **27017 only from the EKS node security group** — so the DB port is
  tight even though the host is exposed. Referencing an SG as the source (not a CIDR) is
  the idiomatic "allow just this tier" pattern.
- **S3 gateway VPC endpoint + endpoint policy:** private S3 access without egressing to
  the internet, and the endpoint *policy* is scoped to the backup bucket (plus a
  platform read-through so EKS/ECR layer pulls work). This is your existing
  endpoint-policy knowledge, applied.

**Likely Q → A.**
- *"SG vs NACL, when?"* → SG for nearly everything (stateful, attached to ENIs); NACL as
  a coarse subnet-wide backstop (e.g. block a CIDR). Here SGs do the real work.
- *"Gateway vs interface endpoint?"* → S3/DynamoDB use **gateway** endpoints (route-table
  entries, free). Most other services use **interface** endpoints (ENI + hourly cost).
- *"Is the database public?"* → The *host* is (SSH 22). The *DB port* is not — SG admits
  only the EKS tier. The real exposure is the public **backup bucket**, not 27017.

---

## 4. IAM & identity

**What it is.** Users/roles, policies (identity vs resource-based), `sts:AssumeRole`,
instance profiles, federation, and org-level guardrails (SCPs, permission boundaries).

**In this project.**
- **Over-permissive instance profile** (`AdministratorAccess` on the VM) — the
  privilege-escalation hinge. Paired with **IMDSv1 allowed**, any local process can read
  those creds.
- **OIDC federation for CI:** GitHub Actions assumes an IAM role via
  `AssumeRoleWithWebIdentity`, trust scoped to `repo:<owner>/<repo>:*`. **No long-lived
  AWS keys in the repo** — the supply-chain best practice.
- **Resource + endpoint policies:** public S3 bucket policy (intentional) and the scoped
  S3 endpoint policy (good).

**Likely Q → A.**
- *"How would you fix the VM role?"* → Scope to the actual need (just `s3:PutObject` to
  the backup prefix), require **IMDSv2** (`http_tokens=required`), and ideally run
  backups via an instance role used only for that. One-line remediations I can do on
  camera.
- *"SCP vs IAM policy?"* → SCPs are org-wide *guardrails* (max permissions, can't grant);
  IAM policies grant within that ceiling. A permission boundary is the per-principal
  version of that ceiling.

---

## 5. DevSecOps taxonomy (know the differences cold)

| Scan type | Question it answers | Tool here | Gate |
|---|---|---|---|
| **SAST** | Insecure code patterns? | Semgrep | advisory |
| **SCA** | Vulnerable dependencies? | Trivy (+ Dependabot) | — / PRs |
| **IaC scan** | Misconfigured infra? | tfsec + checkov | soft-fail (weaknesses accepted) |
| **Image scan** | CVEs in the container? | Trivy | **fail on fixable CRITICAL** |
| **Secret scan** | Credentials committed? | Gitleaks + push protection | **enforced** |
| **SBOM** | What's in the artifact? | Anchore (SPDX) | attached |

**Other pipeline security.** OIDC (keyless AWS auth), **every Action pinned to a commit
SHA** (supply-chain: a tag can be moved, a SHA can't), branch protection + required
checks (`iac-scan`, `app-sast-and-scan`) + CODEOWNERS, deploy by **image digest** not
tag, and a post-deploy step that execs the pod to validate `wizexercise.txt`.

**Likely Q → A.**
- *"Why soft-fail the IaC scan but hard-fail secrets?"* → The infra weaknesses are a
  *required, documented, risk-accepted* part of this exercise, so they're surfaced (not
  silenced) but don't block. A leaked secret or a fixable critical CVE is never
  acceptable, so those gates fail the build.
- *"Why SHA-pin Actions?"* → A compromised or re-pointed tag (`@v4`) can run arbitrary
  code with your token; a SHA is immutable. Dependabot bumps the SHAs safely.

---

## 6. Cloud-native security: preventative vs detective

**Preventative** stops bad things from happening; **detective** tells you they did.
Defense in depth wants both, plus **audit** underneath.

**In this project.**
- **Audit:** CloudTrail (management **+ S3 data events**) and **EKS control-plane logs**
  (all five types). This is the system of record every other control reads from.
- **Detective:** **AWS Config** managed rules (`s3-bucket-public-read-prohibited`,
  `restricted-ssh`, `ec2-imdsv2-check`) continuously flag the misconfigs;
  **GuardDuty** catches the SSH brute-force and anomalous role use.
- **Preventative:** **Kyverno** admission policies in **enforce** mode deny privileged/
  root pods and non-ECR images — demonstrated live without touching the required
  weaknesses (the app itself still passes).

**Likely Q → A.**
- *"Why Kyverno and not just fix the cluster-admin binding?"* → The exercise requires the
  binding to exist; Kyverno shows I can *prevent the class of risk* for new workloads
  (admission control) while leaving the required weakness in place to be detected.
  Preventative + detective, not either/or.
- *"Config vs GuardDuty?"* → Config = *is my configuration compliant* (state). GuardDuty
  = *is something malicious happening* (behavior/threat intel). Different questions.

---

## 7. App & LLM security (your headline differentiator)

**Untrusted `.db` upload.** A SQLite file is *code the parser executes*. Controls in
`app/web/storage.py`: magic-header check (`SQLite format 3\0`), streaming size cap,
open **read-only** (`mode=ro&immutable=1`), `PRAGMA query_only=ON`,
`trusted_schema=OFF`, `enable_load_extension(False)` (kills `load_extension`/`readfile`/
`writefile`), a wall-clock query timeout (DoS), and per-user isolation.

**LLM output is never trusted.** The agent proposes SQL; `src/checker.py` is the
enforcement boundary — it parses with `sqlglot` and allows **only a single read-only
`SELECT`** (no INSERT/UPDATE/DELETE/DDL/`ATTACH`/stacked statements). So **prompt
injection** or a crafted schema can't write or exfiltrate beyond the user's own DB.

**Likely Q → A.**
- *"How do you stop prompt injection?"* → I don't rely on the model refusing. The guard
  + `query_only` connection mean the worst a malicious prompt yields is a `SELECT`
  against the user's own uploaded DB — the blast radius is bounded by architecture, not
  by the LLM's good behavior.
- *"Defense in depth for upload?"* → Four independent layers: it must be a real SQLite
  file (magic header), it can't be too big (cap), the connection *can't* write
  (`query_only`/`mode=ro`), and the SQL *must* be a lone SELECT (guard). Any one failing
  is backed by the next.

---

## 8. Data layer: MongoDB & "outdated software"

**In this project.** MongoDB **5.0** (EOL — intentional weakness) with **auth enabled**,
bound to all interfaces but firewalled to the EKS tier by SG. The connection string is a
**Kubernetes Secret → env var** (`MONGODB_URI`), never baked into the image. Daily
`mongodump` backs up to the (public) bucket.

**Why "outdated" is a real vuln.** Past end-of-life, a version stops receiving security
patches, so known CVEs accrue with no fix path — the same reason the Ubuntu 20.04 AMI
and the deliberately older container base light up scanners. This is the "keeping up
with security news" thread: the finding isn't hypothetical, it's a published CVE the
image/host scanner names.

---

## 9. CNAPP & attack-path thinking (the closer)

**What it is.** A CNAPP (Cloud-Native Application Protection Platform, e.g. **Wiz**)
unifies CSPM (misconfig), CIEM (identity), vulnerability, and workload signals and
correlates them into a **prioritized attack path** graph instead of a flat list of
alerts.

**The pitch for this environment.** Native tools produced five separate signals (a
Config finding, a GuardDuty alert, CloudTrail entries, image CVEs, an RBAC mistake). The
real risk is how they *chain*: internet-facing pod → cluster-admin, and public-SSH host
→ admin role → world-readable backup bucket. A CNAPP shows those as two attack paths to
fix, so you triage by blast radius, not by scrolling 500 findings. See the graph in
[`ARCHITECTURE.md`](ARCHITECTURE.md#attack-path-the-cnapp-graph).

**Likely Q → A.**
- *"Why does a CNAPP beat the native tools you just demoed?"* → The native tools each see
  one dimension. "Public bucket" is medium severity alone; "public bucket holding DB
  dumps that an internet-reachable, admin-roled host writes to" is critical. Only
  correlation across config + identity + exposure + data sensitivity surfaces that, and
  that correlation is exactly what a CNAPP does.
