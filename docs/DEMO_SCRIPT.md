# Live demo runbook

A time-boxed walkthrough of the three acts: **build it, break it, defend it.** Target
~25 minutes of demo inside a 45-minute slot, leaving room for slides and Q&A. Every
command is copy-pasteable; `$(...)` pulls real values from Terraform outputs so you
never hard-code an IP or ARN on stage.

## 0. Pre-flight (do this before the call)

```bash
# Infra is already applied (CI on main, or locally). Point kubectl at the cluster:
cd infra && $(terraform output -raw configure_kubectl) && cd ..
kubectl get nodes                       # nodes Ready, in private subnets
kubectl -n text2sql get pods            # text2sql pod Running

# Grab the values you'll reference on stage:
BUCKET=$(terraform -chdir=infra output -raw backup_bucket)
VM_IP=$(terraform -chdir=infra output -raw mongo_vm_public_ip)
APP_URL=$(kubectl -n text2sql get ingress text2sql -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "app=$APP_URL  bucket=$BUCKET  vm=$VM_IP"
```

Have open in tabs: the app URL, the GitHub Actions run for `main` (green checks), the
AWS consoles for **Config**, **GuardDuty**, and **CloudTrail → Event history**.

> If you have no AWS account on the day, the whole app layer still demos locally
> (`README` quick start) and `pytest` + the Kyverno CLI below run offline.

## Act 1 — Build it (a real product, ~8 min)

**1.1 Use the app.** Open `http://$APP_URL`, sign up, upload `app/data/Chinook.db`,
ask *"Which 5 artists have the most tracks?"* Show the returned **read-only SELECT**,
the rows, and that a second question remembers context (history).

**1.2 Prove MongoDB is the system-of-record.** SSH to the VM and read the collections
the app just wrote:

```bash
ssh ubuntu@"$VM_IP"
mongosh "mongodb://appuser:<pw>@localhost:27017/text2sql?authSource=text2sql" \
  --eval 'db.users.countDocuments(); db.databases.find().limit(1); db.history.find().sort({_id:-1}).limit(1)'
```

This is the live proof for *"the app must leverage MongoDB."* Users, the uploaded-DB
registry, and query history are all there.

**1.3 Prove it's really on EKS, as our image, with the name file.**

```bash
kubectl -n text2sql get deploy text2sql -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
kubectl -n text2sql exec deploy/text2sql -- cat /app/wizexercise.txt     # -> Muhammed Saif
```

The image is an **ECR digest** (not a mutable tag), and `wizexercise.txt` is baked in —
the same check the app pipeline runs post-deploy.

## Act 2 — Break it (the attacker's view, ~8 min)

Run from `security/attack-simulation/`. Order matters: show exposure, then the
host-to-account path, then the pod-to-cluster path.

```bash
# 2.1 Public bucket: anyone, with no AWS account, lists and downloads DB backups.
./01_public_bucket_access.sh "$BUCKET"

# 2.2 SSH is open to the world (generates the GuardDuty signal).
./02_ssh_bruteforce.sh "$VM_IP"

# 2.3 On the VM: IMDSv1 + admin instance role = account takeover.
ssh ubuntu@"$VM_IP" 'bash -s' < ./03_imds_role_theft.sh

# 2.4 From the pod: one internet-facing pod reads every Secret cluster-wide.
kubectl -n text2sql exec deploy/text2sql -- sh -c "$(cat ./04_pod_cluster_admin.sh)"
```

Narrate the hops as you go — each maps to a node in the attack-path graph
([`ARCHITECTURE.md`](ARCHITECTURE.md#attack-path-the-cnapp-graph)).

## Act 3 — Defend it (the defender's view, ~8 min)

**3.1 Shift-left: the pipeline caught it pre-deploy.** Open the `iac-scan` job and show
`tfsec`/`checkov` flagging the public bucket, open SSH, and admin role — findings
surfaced *before* anything deployed. Walk the mapping in
[`SHIFT_LEFT_FINDINGS.md`](../docs/SHIFT_LEFT_FINDINGS.md). Then show the enforced
gates that *do* fail a build: Gitleaks (secrets) and the Trivy CRITICAL gate.

**3.2 Detective controls fired.** In the console:
- **AWS Config** → rule `s3-bucket-public-read-prohibited` = **NON_COMPLIANT** (plus
  `restricted-ssh`, `ec2-imdsv2-check`).
- **GuardDuty** → the SSH brute-force finding from 2.2.
- **CloudTrail** → the anonymous S3 `GetObject` data events from 2.1 and the role
  calls from 2.3.

**3.3 Preventative control, live.** Kyverno is in **enforce** mode. The *existing* app
keeps running, but new bad workloads are denied at admission:

```bash
./05_kyverno_prevention_demo.sh      # privileged pod + non-ECR image: both DENIED
```

You can prove the policy logic with no cluster, straight from the repo, using the
Kyverno CLI:

```bash
kyverno apply security/kyverno/ --resource k8s/        # app resources: PASS
```

## Closer — the CNAPP tie-in (~2 min)

Put the attack-path graph on screen. The message: native tools gave us five separate
signals (a Config finding, a GuardDuty alert, CloudTrail entries, image CVEs, an RBAC
mistake). A CNAPP like **Wiz** correlates misconfiguration + identity + network
exposure + vulnerability into **one prioritized attack path** — "internet-facing pod
with cluster-admin" and "public-SSH host with an admin role feeding a world-readable
bucket" — so you fix the two paths that matter instead of triaging a list of 500.

## Teardown

```bash
kubectl delete -k k8s/ || true
cd infra && terraform destroy
```

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `kubectl` → `Unauthorized` | Cluster applied by a different identity than the pipeline role | The EKS access entry in `eks.tf` covers the GitHub role; for a human, add your ARN to `access_entries` or re-run `update-kubeconfig` as the creator |
| Ingress has no address | AWS LB Controller not installed | `cd infra && ./bootstrap-addons.sh` |
| Pod `CreateContainerConfigError` | `text2sql-secrets` missing | Re-run `scripts/deploy-app.sh` with `MONGODB_URI`/`APP_SECRET_KEY` set |
| Deploy rejected at admission | Image isn't the ECR digest | Deploy via `scripts/deploy-app.sh <ecr>@sha256:...`, not the placeholder tag |
| `/api/ask` → agent unavailable | `FIREWORKS_API_KEY` not set | Add it to the Secret; the rest of the app still demos |
