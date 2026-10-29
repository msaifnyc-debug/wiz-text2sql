#!/usr/bin/env bash
# One-time in-cluster add-ons that are easier via Helm than Terraform:
#   1) AWS Load Balancer Controller (provisions the ALB from the app Ingress)
#   2) Kyverno + the preventative admission policy
#
# Run after `terraform apply` and `aws eks update-kubeconfig ...`.
set -euo pipefail

cd "$(dirname "$0")"
CLUSTER=$(terraform output -raw cluster_name)
REGION=$(terraform output -raw region)
LBC_ROLE=$(terraform output -raw lb_controller_role_arn)
VPC_ID=$(aws eks describe-cluster --name "$CLUSTER" --region "$REGION" \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text)

echo ">> AWS Load Balancer Controller..."
helm repo add eks https://aws.github.io/eks-charts >/dev/null 2>&1 || true
helm repo update >/dev/null

kubectl -n kube-system create serviceaccount aws-load-balancer-controller \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n kube-system annotate serviceaccount aws-load-balancer-controller \
  "eks.amazonaws.com/role-arn=${LBC_ROLE}" --overwrite

helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName="${CLUSTER}" \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region="${REGION}" \
  --set vpcId="${VPC_ID}"

echo ">> Kyverno + preventative policy..."
helm repo add kyverno https://kyverno.github.io/kyverno/ >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade --install kyverno kyverno/kyverno -n kyverno --create-namespace
kubectl apply -f ../security/kyverno/

echo ">> Done. Add-ons installed."
