#!/usr/bin/env bash
# DEMONSTRATES THE PREVENTATIVE CONTROL: Kyverno rejecting bad workloads at admission.
# Expect both attempts to be DENIED with a policy message (the app itself still runs).
set -uo pipefail

echo "[*] Attempt 1: a privileged pod (expected DENY by disallow-privileged-and-root)"
kubectl -n default run badpriv --image=ubuntu:20.04 --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"badpriv","image":"ubuntu:20.04","securityContext":{"privileged":true}}]}}' \
  -- sleep 1 || true

echo
echo "[*] Attempt 2: a non-ECR public image in the app namespace (expected DENY by restrict-image-registries)"
kubectl -n text2sql run badimg --image=nginx:latest --restart=Never || true

echo
echo "[i] Both requests should be blocked by Kyverno before the pod is ever scheduled."
