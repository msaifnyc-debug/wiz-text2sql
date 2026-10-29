#!/usr/bin/env bash
# Deploy the app to EKS with the real image baked into the manifests BEFORE apply.
#
# Why render first: Kyverno's restrict-image-registries policy auto-generates a
# Deployment-level rule, so applying the kustomize placeholder (text2sql-app:latest)
# and patching the image afterwards would be rejected at admission.
#
# Usage: scripts/deploy-app.sh <image-ref>   e.g. 123.dkr.ecr.us-east-1.amazonaws.com/text2sql-app@sha256:...
# Optional env: MONGODB_URI, FIREWORKS_API_KEY, APP_SECRET_KEY -> synced into the K8s Secret.
set -euo pipefail

IMAGE="${1:?usage: deploy-app.sh <image-ref>}"
NS=text2sql
cd "$(dirname "$0")/.."

kubectl apply -f k8s/namespace.yaml

# Requirement: MONGODB_URI reaches the pod as an env var via this Secret.
if [ -n "${MONGODB_URI:-}" ]; then
  kubectl -n "$NS" create secret generic text2sql-secrets \
    --from-literal=MONGODB_URI="$MONGODB_URI" \
    --from-literal=FIREWORKS_API_KEY="${FIREWORKS_API_KEY:-}" \
    --from-literal=SECRET_KEY="${APP_SECRET_KEY:?APP_SECRET_KEY required with MONGODB_URI}" \
    --dry-run=client -o yaml | kubectl apply -f -
fi

kubectl kustomize k8s/ \
  | sed "s#image: text2sql-app:latest#image: ${IMAGE}#" \
  | kubectl apply -f -

kubectl -n "$NS" rollout status deployment/text2sql --timeout=180s
