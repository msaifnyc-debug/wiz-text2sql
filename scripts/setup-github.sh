#!/usr/bin/env bash
# Create the GitHub repo and apply the repository security controls the exercise
# asks for: branch protection, required reviews, required status checks, secret
# scanning + push protection, and Dependabot.
#
# Prereqs: `gh auth login` (GitHub CLI authenticated).
# Usage:   ./scripts/setup-github.sh <github-owner> <repo-name> [public|private]
set -euo pipefail

OWNER="${1:?usage: setup-github.sh <owner> <repo> [visibility]}"
REPO="${2:?usage: setup-github.sh <owner> <repo> [visibility]}"
VIS="${3:-private}"
SLUG="$OWNER/$REPO"

echo ">> Creating $SLUG ($VIS) and pushing main..."
gh repo create "$SLUG" "--$VIS" --source=. --remote=origin --push

echo ">> Enabling secret scanning + push protection and vulnerability alerts..."
gh api -X PATCH "repos/$SLUG" \
  -f security_and_analysis.secret_scanning.status=enabled \
  -f security_and_analysis.secret_scanning_push_protection.status=enabled >/dev/null
gh api -X PUT "repos/$SLUG/vulnerability-alerts" >/dev/null
gh api -X PUT "repos/$SLUG/automated-security-fixes" >/dev/null

echo ">> Applying branch protection on main (reviews + required checks + code owners)..."
gh api -X PUT "repos/$SLUG/branches/main/protection" \
  --input .github/branch-protection.json >/dev/null

echo ">> Done. Configure the OIDC role ARN as repo variable AWS_ROLE_ARN:"
echo "   gh variable set AWS_ROLE_ARN --body \"\$(terraform -chdir=infra output -raw gha_deploy_role_arn)\""
echo ">> Then the deploy secrets (scripts/deploy-app.sh syncs them into the K8s Secret):"
echo "   gh secret set MONGODB_URI --body \"\$(terraform -chdir=infra output -raw mongodb_uri)\""
echo "   gh secret set APP_SECRET_KEY --body \"\$(openssl rand -hex 32)\""
echo "   gh secret set FIREWORKS_API_KEY    # paste the key when prompted"
