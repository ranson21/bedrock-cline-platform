# bedrock-cline-platform — operator entry points
#
# Usage: make <target> ENV=<name>   where terragrunt/live/<name>/ exists
#
ENV ?= dev
LIVE := terragrunt/live/$(ENV)
TG  ?= terragrunt
PY  ?= python3
MODULES := $(wildcard terraform/modules/*)

.PHONY: help preflight bootstrap plan apply destroy smoke usage profiles lint fmt validate test sync-docs clean

help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

preflight: ## Verify AWS auth, partition, Bedrock model enablement, Identity Center
	@test -d $(LIVE) || (echo "missing $(LIVE); copy terragrunt/live/example" && exit 1)
	bash tools/preflight/preflight.sh $(LIVE)

bootstrap: ## Create the Terraform state bucket and lock table (run once per account)
	bash tools/preflight/bootstrap.sh $(LIVE)

plan: ## terragrunt run-all plan (Lambda zips are built by the archive provider)
	cd $(LIVE) && $(TG) run-all plan --terragrunt-non-interactive

apply: ## terragrunt run-all apply in dependency order
	cd $(LIVE) && $(TG) run-all apply --terragrunt-non-interactive

destroy: ## Destroy everything in the environment (asks for confirmation)
	cd $(LIVE) && $(TG) run-all destroy

profiles: ## Print each engineer's inference profile ARNs
	cd $(LIVE)/bedrock-core && $(TG) output -json engineer_profiles | $(PY) -c 'import json,sys; d=json.load(sys.stdin); [print(f"{u}\n  " + "\n  ".join(f"{t}: {a}" for t,a in p.items())) for u,p in sorted(d.items())]'

smoke: ## Invoke every profile, verify prompt caching, test knowledge-base retrieval
	$(PY) tools/smoke/smoke.py --live $(LIVE)

usage: ## Per-engineer usage, cache hit rate, burn rate and projection for this month
	$(PY) tools/usage-report/usage_report.py --live $(LIVE)

sync-docs: ## Upload docs to the knowledge-base bucket and start ingestion
	$(PY) tools/sync-docs/sync_docs.py --live $(LIVE) $(ARGS)

fmt: ## Format Terraform and Terragrunt
	terraform fmt -recursive terraform
	$(TG) hclfmt --terragrunt-working-dir terragrunt

validate: ## terraform validate every module without a backend
	@for m in $(MODULES); do echo "== $$m"; (cd $$m && terraform init -backend=false -input=false >/dev/null && terraform validate) || exit 1; done

lint: fmt validate ## fmt + validate + tflint + checkov (if installed)
	@command -v tflint >/dev/null && for m in $(MODULES); do (cd $$m && tflint --config ../../../.tflint.hcl) || exit 1; done || echo "tflint not installed, skipping"
	@command -v checkov >/dev/null && checkov -d terraform --config-file .checkov.yaml || echo "checkov not installed, skipping"
	@command -v ruff >/dev/null && ruff check tools terraform/modules/*/lambda || echo "ruff not installed, skipping"

test: ## Python unit tests for the budget guard and tools
	$(PY) -m pytest -q terraform/modules/budget-guard/tests tools

clean:
	find . -name '*.zip' -path '*/lambda/*' -delete
	find . -name '.terragrunt-cache' -type d -prune -exec rm -rf {} +
