# bedrock-cline-platform

Self-hosted, agency-owned replacement for hosted AI coding assistants. Engineers use the
open source [Cline](https://github.com/cline/cline) extension in VS Code, pointed at Claude
models running in **Amazon Bedrock inside your own AWS account**. Everything else in this repo
exists to make that safe, attributable, and affordable for a team of 25 or more engineers doing
heavy agentic work: identity, per-engineer budgets, prompt-cache enforcement, a shared
knowledge base on OpenSearch, invocation logging, and dashboards.

It is written to be pointed at **any AWS account ID** in either the commercial (`aws`) or
GovCloud (`aws-us-gov`) partition. Nothing account-specific is hardcoded.

```
VS Code + Cline ──SigV4 (Identity Center SSO)──▶ Amazon Bedrock ──▶ Claude Opus 5 / Sonnet 5
       │                                            │
       │ MCP tool: search_knowledge_base            │ invocation logs (CMK encrypted)
       ▼                                            ▼
Bedrock Knowledge Base ◀── S3 docs          CloudWatch Logs ──▶ Budget Guard Lambda ──▶ DynamoDB
(OpenSearch Serverless vectors)                                     │ tags profile "exhausted"
                                                                    ▼
                                                     SNS alerts · usage dashboards · OpenSearch analytics
```

## Contents

| Path | What it is |
|---|---|
| `terragrunt/` | Root config plus one directory per account. Copy `live/example` to `live/<your-env>` and edit `account.hcl` and `engineers.yaml`. |
| `terraform/modules/` | Plain Terraform modules: `bootstrap`, `identity`, `bedrock-core`, `budget-guard`, `knowledge-base`, `observability`, `network` (optional), `gateway` (optional). |
| `tools/` | `preflight` checks, `smoke` tests, `usage-report`, `budget-ctl`, `sync-docs`, and the `mcp-kb-server` that gives Cline retrieval over your docs. |
| `cline/` | Settings templates, MCP registration, and a `.clinerules` file tuned for token economy. |
| `docs/` | Architecture, deploy, Cline setup, onboarding, budget tuning, GovCloud notes, security, runbooks. |

## Quick start

1. Read `docs/deploy.md`. The short version:
   ```bash
   cp -r terragrunt/live/example terragrunt/live/dev
   $EDITOR terragrunt/live/dev/account.hcl      # account id, partition, region
   $EDITOR terragrunt/live/dev/engineers.yaml   # who gets access, which models, budgets
   make preflight ENV=dev    # verifies auth, partition, model enablement, Identity Center
   make bootstrap ENV=dev    # state bucket + lock table, once per account
   make apply ENV=dev        # terragrunt run-all apply in dependency order
   make smoke ENV=dev        # invokes each profile, proves caching works, tests KB retrieve
   ```
2. Give each engineer `docs/cline-setup.md`. Their per-engineer inference profile ARN is printed by
   `make profiles ENV=dev`.
3. The knowledge base starts empty. Follow `docs/knowledge-base-seeding.md` to have Cline itself
   analyze each codebase and write the documents that get indexed.
4. Watch spend with `make usage ENV=dev` or the CloudWatch dashboard the `observability` module creates.

## Governance

### Why this works in a FedRAMP environment

This platform is a set of AWS-native services, not a SaaS product, so the authorization
boundary is your AWS account. Points that matter to an assessor:

- **Inference stays inside your boundary.** Claude runs on Amazon Bedrock in AWS GovCloud (US),
  which is FedRAMP High authorized and approved for DoD IL4 and IL5 workloads. Prompts, code, and
  completions never leave the account. Bedrock does not use your data to train models, and the
  Opus 5 offering in GovCloud runs with zero data retention by default. Confirm current status on
  the [AWS Services in Scope](https://aws.amazon.com/compliance/services-in-scope/) list before
  citing it in your SSP.
- **No third-party control plane.** Cline is a local VS Code extension. There is no vendor cloud
  between the editor and Bedrock. The optional gateway module is also self-hosted, inside your VPC.
- **Identity is your identity.** Access is granted through IAM Identity Center permission sets
  and attribute-based access control. Each engineer can invoke only the application inference
  profiles tagged with their own username. There are no API keys to leak or rotate.
- **Complete, attributable audit trail.** Bedrock model invocation logging captures every
  request and response with the caller's identity ARN and token counts, encrypted with a
  customer-managed KMS key, retained in CloudWatch Logs and S3 with configurable retention.
  CloudTrail records the management plane. Long-lived bearer tokens are denied by policy.
- **Least privilege by construction.** Permission sets grant `InvokeModel` only on
  `application-inference-profile/*` resources carrying a matching `owner` tag, and only on the
  foundation models those profiles wrap. Bare model IDs cannot be invoked directly.
- **Content controls are available.** The `bedrock-core` module can create a Bedrock Guardrail
  with PII masking and denied topics. It is enforced automatically in gateway mode and available
  to any client that passes a guardrail identifier.
- **Everything is code.** Terraform and Terragrunt define the whole environment, so the
  configuration an assessor reviews is the configuration that is deployed. CI runs `checkov`
  and `tflint` on every change.

### How it beats Copilot for heavy agentic coding

| | Copilot agent mode | This platform |
|---|---|---|
| Where inference runs | GitHub and Microsoft operated infrastructure, outside your AWS boundary. Check the FedRAMP Marketplace for its current authorization before relying on it. | Your AWS account, in GovCloud if you choose. |
| Model choice | Fixed menu, with per-model request multipliers. | Any Claude model enabled in your account, including Opus 5 and 1M-context models. Per engineer, per team. |
| Metering | Premium request quotas per seat, then per-request overage. Long agentic runs burn quota fast. | Pay per token, with caching. A per-engineer dollar and token budget you set, enforced by the platform. |
| Context window | Managed by the vendor. | Up to 1M tokens on current Claude models. |
| Tooling | Vendor-defined tools. | Cline supports MCP. This repo ships a knowledge-base tool; add your own. |
| Autonomy | Vendor-controlled auto-approve rules. | Full control of auto-approve, checkpoints, and rules per repo via `.clinerules`. |
| Cost visibility | Seat-level. | Per engineer, per team, per model, per day, from your own logs. |
| Lock-in | Proprietary client and service. | Apache-2.0 infra, open source client, standard Bedrock APIs. |

The practical difference for a 25-engineer team: an engineer can leave a multi-hour agentic task
running against a 400k-token context without hitting a request quota, and the bill for it is
visible the same day, attributed to them, and capped by policy.

### How it compares to Claude Max

Claude Max is the other obvious way to give an engineer Claude Code with Opus-class models.
It is a flat $200 per seat per month, and it is a consumer subscription to Anthropic's
commercial service, so prompts and code leave your authorization boundary. Cost comparison at
one 5M-token block of Opus 5 per engineer per month, caching on, hosting share included
(see `docs/cost.md`):

| Headcount | This platform, all-in per engineer | Claude Max per seat | Savings |
|---|---|---|---|
| 8 | ~$89 | $200 | ~55% |
| 12 | ~$66 | $200 | ~67% |
| 25 | ~$42 | $200 | ~79% |

The comparison flips only for very heavy individual use: Max is effectively flat, this
platform is metered. An engineer would need to bill roughly 40M tokens of Opus 5 cached in a
month before crossing $200 at 12 headcount, and at that volume Sonnet 5 for routine work keeps
the same month near $90. The budget guard makes that visible within a day rather than at the
invoice. For a team whose prior usage averaged about 3M tokens per engineer per month, the
cost advantage holds with wide headroom, and the boundary advantage holds regardless of price.

### Budget model: making 5.7M tokens per engineer per month work

Cost is a fixed baseline plus per-engineer token blocks:

```
monthly cost = baseline infra (~$550 core) + Σ engineers (5M-token blocks × block price)
```

| Model, GovCloud estimate | 5M block, caching off | 5M block, caching on |
|---|---|---|
| Claude Opus 5 | ~$42 | ~$20 |
| Claude Sonnet 5 | ~$17 | ~$8 |

So the default budget of **$48 per engineer per month** is about one 5M block of Opus 5 uncached,
or roughly 2.4 blocks (12M tokens) with caching on, or 6 blocks (30M tokens) on Sonnet 5 cached.
Cached prefix tokens bill at about one tenth of the input rate, which is why caching is enforced
rather than suggested. Full tables, per-engineer examples, and the levers are in `docs/cost.md`.

The platform makes that budget real rather than aspirational:

1. **Budget Guard** (`terraform/modules/budget-guard`) meters every invocation from the logs,
   keeps per-engineer monthly counters in DynamoDB, alerts at 50/80/100 percent through SNS,
   and at 100 percent tags the engineer's inference profiles `budget_state=exhausted`. The
   permission set denies invocation on that tag. Access returns automatically on the first of
   the month or when an admin runs `budget-ctl grant`.
2. **Cache enforcement.** The smoke test proves caching works in your account. The budget guard
   tracks each engineer's cache hit rate, nudges them when it drops below the threshold, and
   can lock the profile with `budget_state=cache_disabled` until caching is turned back on.
   In gateway mode, cache breakpoints are injected server-side so the client cannot forget.
3. **Model tiering.** Engineers get a Sonnet 5 profile by default and an Opus 5 profile only
   when listed in `engineers.yaml`. Spend on each is visible separately.
4. **Client hygiene.** `cline/.clinerules` and `docs/cline-setup.md` set context limits,
   auto-compaction, and terse-output conventions that cut token volume before it reaches Bedrock.
5. **Reporting.** `make usage` shows burn rate, projected month-end spend, cache hit rate, and
   the top consumers, so you can tune budgets against observed behavior instead of guessing.

See `docs/cost.md` for the full tuning guide.

## Documentation

- `docs/architecture.md`, `docs/deploy.md`, `docs/cline-setup.md`, `docs/onboarding.md`
- `docs/knowledge-base-seeding.md` (fill the empty index using the agent) with the task prompt in `cline/prompts/kb-seed.md`
- `docs/knowledge-base-ui.md` (prompt to build a role-gated KB search/Q&A feature into your existing app)
- `docs/cost.md` (budget tuning), `docs/budget-guard.md` (how enforcement works)
- `docs/govcloud-notes.md`, `docs/security-and-compliance.md`
- `docs/runbooks/` for day-two operations

## License

Apache License 2.0. See `LICENSE` and `NOTICE`.
