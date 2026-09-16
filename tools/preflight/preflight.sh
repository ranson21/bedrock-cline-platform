#!/usr/bin/env bash
# Pre-deploy checks. Usage: tools/preflight/preflight.sh terragrunt/live/<env>
set -euo pipefail
LIVE="${1:?live dir}"
ACCOUNT_ID=$(sed -n 's/^\s*account_id\s*=\s*"\([^"]*\)".*/\1/p' "$LIVE/account.hcl")
PARTITION=$(sed -n 's/^\s*partition\s*=\s*"\([^"]*\)".*/\1/p' "$LIVE/account.hcl")
REGION=$(sed -n 's/^\s*region\s*=\s*"\([^"]*\)".*/\1/p' "$LIVE/account.hcl")
PREFIX=$(sed -n 's/^\s*name_prefix\s*=\s*"\([^"]*\)".*/\1/p' "$LIVE/account.hcl")
export AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION"
ok()   { printf '  \033[32m✔\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
fail() { printf '  \033[31m✘\033[0m %s\n' "$*"; FAILED=1; }
FAILED=0

echo "== Tooling"
for t in terraform terragrunt aws python3; do command -v "$t" >/dev/null && ok "$t $($t --version 2>/dev/null | head -1)" || fail "$t not installed"; done
python3 -c 'import boto3, yaml' 2>/dev/null && ok "python: boto3 + pyyaml" || warn "pip install boto3 pyyaml (needed by tools/)"

echo "== Identity"
if IDENT=$(aws sts get-caller-identity --output json 2>/dev/null); then
  ACCT=$(echo "$IDENT" | python3 -c 'import sys,json; print(json.load(sys.stdin)["Account"])')
  ARN=$(echo "$IDENT" | python3 -c 'import sys,json; print(json.load(sys.stdin)["Arn"])')
  [ "$ACCT" = "$ACCOUNT_ID" ] && ok "account $ACCT ($ARN)" || fail "authenticated to $ACCT but account.hcl says $ACCOUNT_ID"
  case "$ARN" in arn:${PARTITION}:*) ok "partition $PARTITION";; *) fail "credentials are not in partition $PARTITION";; esac
else
  fail "no AWS credentials (aws sso login --profile <admin-profile>)"; exit 1
fi

echo "== Bedrock in $REGION"
if MODELS=$(aws bedrock list-foundation-models --by-provider anthropic --query 'modelSummaries[].modelId' --output text 2>/dev/null); then
  ok "anthropic models visible: $(echo "$MODELS" | wc -w)"
  echo "$MODELS" | tr '\t' '\n' | sed 's/^/      /'
else
  fail "cannot list foundation models (Bedrock unavailable in region or missing permission)"
fi
PROFILES=$(aws bedrock list-inference-profiles --type-equals SYSTEM_DEFINED --query 'inferenceProfileSummaries[].inferenceProfileId' --output text 2>/dev/null | tr '\t' '\n' | grep anthropic || true)
[ -n "$PROFILES" ] && { ok "system inference profiles (cross-region):"; echo "$PROFILES" | sed 's/^/      /'; } || warn "no cross-region anthropic profiles listed"
python3 - "$LIVE" "$MODELS" "$PROFILES" <<'PY'
import sys, yaml
live, models, profiles = sys.argv[1], sys.argv[2].split(), sys.argv[3].split()
cfg = yaml.safe_load(open(f"{live}/engineers.yaml"))
tiers = cfg.get("model_tiers", {})
used = {t for e in cfg.get("engineers", []) for t in (e.get("models") or cfg["defaults"]["models"])}
for t in sorted(used):
    m = tiers[t]["model_id"]
    if tiers[t].get("cross_region"):
        hit = any(p.endswith(m) for p in profiles)
    else:
        hit = m in models
    print(("  \033[32m✔\033[0m" if hit else "  \033[31m✘\033[0m") + f" tier {t} -> {m} " + ("" if hit else "(NOT FOUND: enable model access or fix model_tiers)"))
PY
if aws bedrock get-model-invocation-logging-configuration >/dev/null 2>&1; then ok "invocation logging API reachable"; fi

echo "== Identity Center"
if aws sso-admin list-instances --query 'Instances[0].InstanceArn' --output text 2>/dev/null | grep -q arn; then
  ok "Identity Center instance found"
  STORE=$(aws sso-admin list-instances --query 'Instances[0].IdentityStoreId' --output text)
  for g in $(python3 -c "import yaml,sys; c=yaml.safe_load(open('$LIVE/engineers.yaml')); print(c['groups']['engineers'], c['groups']['admins'])"); do
    aws identitystore list-groups --identity-store-id "$STORE" --filters "AttributePath=DisplayName,AttributeValue=$g" --query 'Groups[0].GroupId' --output text 2>/dev/null | grep -qv None && ok "group $g exists" || warn "group $g not found (create it in your IdP/Identity Center or set manage_identity_store=true)"
  done
else
  fail "IAM Identity Center is not enabled in this account/region (enable it, or use an org delegated admin)"
fi

echo "== OpenSearch Serverless"
aws opensearchserverless list-collections >/dev/null 2>&1 && ok "aoss reachable" || fail "OpenSearch Serverless not available in $REGION"

echo "== State backend"
BUCKET="${PREFIX}-tfstate-${ACCOUNT_ID}-${REGION}"
aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1 && ok "state bucket $BUCKET exists" || warn "state bucket $BUCKET missing: run make bootstrap"

[ "$FAILED" = 0 ] && echo "preflight OK" || { echo "preflight FAILED"; exit 1; }
