# tools/

Operator and engineer tooling for the platform. Everything here is a thin Python or bash
script over the AWS SDK; nothing runs as a service. Most are wired to `make` targets, which
is the intended entry point.

All Python tools take `--live terragrunt/live/<env>` (they read `account.hcl` for the account
id and region and Terragrunt outputs for resource names) and an optional `--profile <aws
profile>`. They refuse to run if your credentials resolve to a different account than the
one in `account.hcl`.

Install dependencies once: `pip install -r tools/requirements.txt`.

| Tool | Who runs it | What it does | `make` target |
|---|---|---|---|
| `preflight/preflight.sh` | admin, before first deploy | Read-only checks: tooling, credentials in the right account and partition, Bedrock model access for every tier in `engineers.yaml`, Identity Center instance and groups, OpenSearch Serverless reachability, state bucket. Creates nothing, costs nothing. | `make preflight` |
| `preflight/bootstrap.sh` | admin, once per account | Creates the Terraform state bucket, lock table and KMS key with local state, using the `bootstrap` module. | `make bootstrap` |
| `smoke/smoke.py` | admin, after every apply | Invokes every engineer inference profile, proves prompt caching works by sending a cached prompt twice and checking `cacheReadInputTokens`, and runs a knowledge-base retrieve. Exit code 1 on any failure. | `make smoke` |
| `usage-report/usage_report.py` | admin, weekly | Per-engineer month-to-date usage from the budget guard table: requests, tokens, cache hit rate, average context size, oversized requests, spend, budget, percent used, projected month-end, state. `--json` for machine output, `--month YYYY-MM` for history. | `make usage` |
| `budget-ctl/budget_ctl.py` | admin, on demand | Runtime budget administration without a Terraform apply: `status`, `grant` (temporary override through month end), `unlock`, `lock`, `clear-override`, `reset-all`. | none; run directly |
| `sync-docs/sync_docs.py` | admin or doc owner | Uploads a local directory to the knowledge-base bucket (changed files only, deletes removed ones under the prefix), starts an ingestion job, `--wait` for completion. | `make sync-docs ARGS="--src ./knowledge --prefix repos/ --wait"` |
| `mcp-kb-server/` | every engineer | Local MCP server that gives Cline a `search_knowledge_base` tool backed by the Bedrock Knowledge Base, using the engineer's own SSO credentials. Installed with `pipx install ./tools/mcp-kb-server`; registered in Cline per `docs/cline-setup.md`. | none |
| `common/live.py` | (library) | Shared helpers: parse `account.hcl`, read Terragrunt outputs, build a boto3 session that assumes `deploy_role_arn` if set and verifies the account id. | |

## Examples

```bash
# Before the first deploy in a new account
make preflight ENV=dev

# After apply: does it actually work, and is caching on?
make smoke ENV=dev

# Who is spending what this month, and who has caching off or huge contexts?
make usage ENV=dev
python tools/usage-report/usage_report.py --live terragrunt/live/dev --month 2026-08 --json > aug.json

# An engineer hit their cap during release week
python tools/budget-ctl/budget_ctl.py --live terragrunt/live/dev status jane.doe
python tools/budget-ctl/budget_ctl.py --live terragrunt/live/dev grant jane.doe --usd 120 --note "release week"

# Someone turned caching off and got locked; they fixed it, let them back in
python tools/budget-ctl/budget_ctl.py --live terragrunt/live/dev unlock jane.doe

# Seed or refresh the knowledge base from a repo's knowledge/ directory
make sync-docs ENV=dev ARGS="--src ../my-service/knowledge --prefix repos/ --wait"
```

## Conventions

- Tools never print account ids or secrets. Usernames and spend are printed because that is
  the point of the report; treat the output as internal.
- Read-only tools (`preflight`, `smoke`, `usage-report`) are safe to run at any time.
  `budget-ctl lock|unlock|grant|reset-all` change tags and table rows; `sync-docs` writes to
  S3 and can delete objects under the prefix you pass.
- `tests/`-style checks live next to the code they test. `make test` runs the budget-guard unit
  tests and a compile check over every tool; CI runs the same.
- Adding a tool: put it in its own directory with a module docstring that states usage,
  import `common.live` for account handling, add a row to this table and a `make` target if
  admins will run it routinely.
