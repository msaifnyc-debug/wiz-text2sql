# Requirements traceability

Every requirement of the exercise → where it's implemented → how to prove it live.
Use this to self-check completeness and to answer "where exactly is X?" on the spot.

## Application & container

| # | Requirement | Implementation | Live proof |
|---|---|---|---|
| 1 | Containerized web app | `app/` (FastAPI), `app/Dockerfile` (multi-stage, non-root uid 10001) | app loads at the ALB URL |
| 2 | App uses **MongoDB** | `app/web/mongo.py` — collections `users`, `databases`, `history` | `mongosh` shows the docs (Demo 1.2) |
| 3 | Mongo connection string as a **K8s env var** | `k8s/deployment.yaml` `envFrom` → Secret `text2sql-secrets`; `scripts/deploy-app.sh` creates it from `MONGODB_URI` | `kubectl -n text2sql exec deploy/text2sql -- printenv MONGODB_URI` |
| 4 | **`wizexercise.txt`** with your name, in the container | `wizexercise.txt` ("Muhammed Saif"), `COPY` in `app/Dockerfile` | `kubectl ... exec ... cat /app/wizexercise.txt`; also validated in `app.yml` post-deploy |

## Database VM (intentional weaknesses)

| # | Requirement | Implementation | Live proof |
|---|---|---|---|
| 5 | DB on a **VM**, not a managed service | `infra/mongo_vm.tf` (EC2), `infra/user_data.sh.tpl` installs MongoDB | `aws ec2 describe-instances`; `ssh` + `mongosh` |
| 6 | DB **authentication** enabled | `user_data.sh.tpl` sets `security.authorization: enabled`, creates `admin` + `appuser` | connecting without creds is refused |
| 7 | **Outdated** DB version (1+ yr / EOL) | MongoDB **5.0** (`var.mongodb_version`) | `mongosh --eval 'db.version()'` |
| 8 | **Outdated** OS | Ubuntu 20.04 "focal" AMI (`data.aws_ami.ubuntu_focal`) | `ssh ... 'lsb_release -a'` |
| 9 | VM **SSH open to the internet** | `mongo_vm.tf` SG ingress 22 from `var.ssh_ingress_cidr` (default `0.0.0.0/0`) | `02_ssh_bruteforce.sh`; Config `restricted-ssh` |
| 10 | VM **over-permissive IAM role** | `infra/iam.tf` instance profile → `AdministratorAccess`; IMDSv1 allowed (`http_tokens=optional`) | `03_imds_role_theft.sh` |
| 11 | VM in a **public subnet** w/ public IP | `mongo_vm.tf` `subnet_id = public_subnets[0]`, `associate_public_ip_address = true` | public IP in `terraform output` |

## Object storage (intentional weakness)

| # | Requirement | Implementation | Live proof |
|---|---|---|---|
| 12 | **Automated DB backups** to object storage | `user_data.sh.tpl` daily `mongodump` cron → `s3://<bucket>/backups/` | objects appear in the bucket |
| 13 | Bucket **publicly readable + listable** | `infra/s3_backups.tf` (public access block off, public read+list bucket policy) | `01_public_bucket_access.sh` (anonymous); Config `s3-bucket-public-read-prohibited` |

## Kubernetes & exposure

| # | Requirement | Implementation | Live proof |
|---|---|---|---|
| 14 | Managed **Kubernetes (EKS)**, nodes **private** | `infra/eks.tf` nodes/pods in `private_subnets` | `kubectl get nodes -o wide` (no public IPs) |
| 15 | App container has **cluster-admin** | `k8s/serviceaccount.yaml` + `k8s/clusterrolebinding.yaml` → `cluster-admin` | `04_pod_cluster_admin.sh` reads Secrets cluster-wide |
| 16 | App **exposed to the internet** | `k8s/ingress.yaml` (internet-facing ALB via LB Controller) | the public ALB URL serves the app |

## Infrastructure as Code

| # | Requirement | Implementation | Live proof |
|---|---|---|---|
| 17 | **Everything** via IaC | `infra/*.tf` (VPC, EKS, VM, S3, IAM, ECR, CloudTrail, Config, GuardDuty) | `terraform plan` is the full environment |

## CI/CD (two pipelines + pipeline security)

| # | Requirement | Implementation | Live proof |
|---|---|---|---|
| 18 | **IaC pipeline** | `.github/workflows/infra.yml` (fmt/validate → plan on PR → apply on main) | green `iac-scan` check |
| 19 | **App pipeline** (build → push → deploy) | `.github/workflows/app.yml` (build → ECR → EKS by digest) | green `build-push-deploy`; rollout succeeds |
| 20 | **Image scanning** | Trivy report + **fail on fixable CRITICAL** | Trivy step in `app.yml` |
| 21 | Security **in CI/CD** (bonus) | Semgrep (SAST), Gitleaks (secrets, enforced), checkov/tfsec (IaC), Anchore SBOM, OIDC, **SHA-pinned** actions, Dependabot, branch protection, CODEOWNERS | the pipeline files + `.github/` |
| 22 | Post-deploy **`wizexercise.txt`** validation | `app.yml` execs the running pod and prints the file | the pipeline log |

## Cloud-native security controls

| # | Requirement | Implementation | Live proof |
|---|---|---|---|
| 23 | **Audit logging** | `infra/cloudtrail.tf` (management + S3 **data events**); `eks.tf` all 5 control-plane log types | CloudTrail Event history; CloudWatch EKS logs |
| 24 | **Detective** control | `infra/config.tf` (`s3-bucket-public-read-prohibited`, `restricted-ssh`, `ec2-imdsv2-check`); `infra/guardduty.tf` | Config NON_COMPLIANT; GuardDuty finding |
| 25 | **Preventative** control | `security/kyverno/*.yaml` (enforce mode); installed by `infra/bootstrap-addons.sh` | `05_kyverno_prevention_demo.sh` denies bad pods |
| 26 | **Demonstrate** the controls | `security/attack-simulation/*.sh` + `security/TEST_MATRIX.md` | run the scripts (Demo Act 2/3) |

## Presentation

| # | Requirement | Implementation |
|---|---|---|
| 27 | Architecture diagram | [README](../README.md#architecture) + [ARCHITECTURE.md](ARCHITECTURE.md) |
| 28 | Attack-path / story | [ARCHITECTURE.md](ARCHITECTURE.md#attack-path-the-cnapp-graph), [SLIDES.md](SLIDES.md) |
| 29 | Live demo script | [DEMO_SCRIPT.md](DEMO_SCRIPT.md) |
| 30 | Concepts to speak to | [CONCEPTS.md](CONCEPTS.md) |

---

### Known gaps / honest caveats (say these before they ask)
- **IaC scan is soft-fail** by design — the infra weaknesses are required and
  risk-accepted; secret and image-CVE gates *are* enforced.
- **Kyverno doesn't undo the cluster-admin binding** — the requirement needs it to
  exist; Kyverno prevents the *class* of risk on new workloads instead.
- **Cluster API endpoint is public** for demo `kubectl` convenience; nodes/pods are
  private. Flip `cluster_endpoint_public_access = false` to tighten.
- **One NAT gateway** (not one per AZ) to keep the exercise cheap — a cost/HA trade-off,
  not a security one.
