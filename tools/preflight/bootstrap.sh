#!/usr/bin/env bash
# Create the remote-state bucket and lock table with local state, once per account.
set -euo pipefail
LIVE="${1:?live dir}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ACCOUNT_ID=$(sed -n 's/^\s*account_id\s*=\s*"\([^"]*\)".*/\1/p' "$LIVE/account.hcl")
REGION=$(sed -n 's/^\s*region\s*=\s*"\([^"]*\)".*/\1/p' "$LIVE/account.hcl")
PREFIX=$(sed -n 's/^\s*name_prefix\s*=\s*"\([^"]*\)".*/\1/p' "$LIVE/account.hcl")
ENV=$(sed -n 's/^\s*environment\s*=\s*"\([^"]*\)".*/\1/p' "$LIVE/account.hcl")
WORK="$ROOT/$LIVE/.bootstrap"
mkdir -p "$WORK"
cp "$ROOT"/terraform/modules/bootstrap/*.tf "$WORK/"
cd "$WORK"
export AWS_REGION="$REGION"
terraform init -input=false >/dev/null
terraform apply -input=false -auto-approve \
  -var "name_prefix=$PREFIX" -var "account_id=$ACCOUNT_ID" -var "region=$REGION" \
  -var "tags={Project=\"bedrock-cline-platform\",Environment=\"$ENV\",ManagedBy=\"bootstrap\"}"
echo
echo "Bootstrap state is in $WORK/terraform.tfstate — keep it (it is gitignored) or import the bucket later."
