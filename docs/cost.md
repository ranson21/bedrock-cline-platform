# Cost model and budget tuning

Last reviewed 2026-09-16. Token prices are AWS list prices for GovCloud (US-West); infrastructure
figures are estimates derived from list prices, rounded. They are not a quote. **When you localize this file, keep it free of your account's
actual spend, negotiated discounts (EDP/PPA), and account identifiers** if the repo stays public.

The model is deliberately simple:

```
monthly cost  =  fixed baseline (~$550)  +  Σ engineers ( token blocks used × price per 5M-token block )
per-engineer  =  baseline ÷ headcount    +  that engineer's blocks × block price
```

## 1. Fixed baseline (the platform, before anyone sends a token)

The baseline is a **flat monthly platform cost**. It is the same whether one engineer or fifty
use the platform, and it is *not* attached to the first engineer. Nearly all of it is the
OpenSearch Serverless collection behind the knowledge base, which bills for provisioned
compute units around the clock.

| Component | Sizing | USD / month |
|---|---|---|
| OpenSearch Serverless, KB vector collection | 2 OCU, standby DISABLED | ~350 |
| OpenSearch Serverless, usage analytics collection (optional, on by default) | shares account OCU pool, plus storage | ~0–200 |
| Bedrock invocation logging (CloudWatch Logs + S3, CMK) | scales gently with usage | ~40–120 |
| Budget Guard (Lambda, DynamoDB, SNS, SSM, EventBridge) | pay-per-request | ~5 |
| KMS keys (3), dashboard, alarms | | ~8 |
| **Core baseline, plan on** | | **~550** (range 425–685) |
| **Lean baseline** (analytics collection off, CloudWatch dashboard only) | | **~400** |
| Optional: network (10 interface endpoints, flow logs, no NAT) | | +~90 |
| Optional: Client VPN (endpoint + 2 subnet associations, before connection-hours) | | +~150 |
| Optional: gateway (2× Fargate 1 vCPU / 2 GB, internal ALB) | | +~100 |
| Optional: gateway database (db.t4g.micro Postgres) | | +~15 |
| **Everything on** | | **~800–1050** |

GovCloud runs roughly 15–25% above commercial list; the ranges lean high already. Enabling
`standby_replicas = ENABLED` doubles that collection's OCU line. The analytics collection is
the one baseline item you can remove without losing any enforcement: set
`enable_analytics_collection = false` in the observability unit and the budget guard still
meters and enforces from DynamoDB.

## 2. Price per 5M-token block

Bedrock list prices per 1M tokens for **AWS GovCloud (US-West)**, read from the Anthropic
"Geo and In-region" table at https://aws.amazon.com/bedrock/pricing/ on 2026-09-16. GovCloud is
exactly 1.2x the global rate (the commercial "us." geo profiles are 1.1x). Keep `prices:` in
`engineers.yaml` in sync when AWS changes them.

| Model | Input | Cache write (5m) | Cache read | Output | Batch in / out |
|---|---|---|---|---|---|
| Claude Opus 5 | 6.00 | 7.50 | 0.60 | 30.00 | 3.00 / 15.00 |
| Claude Sonnet 5 | 2.40 | 3.00 | 0.24 | 12.00 | n/a |
| Claude Opus 4.8 | 6.00 | 7.50 | 0.60 | 30.00 | n/a |
| Claude Fable 5.1 | 12.00 | 15.00 | 0.30 | 60.00 | n/a |
| Claude Haiku 4.5 | not listed for GovCloud at review; 1.20 / 1.50 / 0.12 / 6.00 if it follows the 1.2x pattern | | | | |

Claude Fable 5 and Sonnet 4.6 show N/A for GovCloud (US-West) on the pricing page at review time.

What one **5M-token block** costs depends on how much of it is cached. Two reference mixes:

- **Uncached**: 90% input, 10% output. What you pay if "Use prompt caching" is off.
- **Cached**: 10% fresh input, 80% cache read, 10% output. Typical for Cline with caching on.

| Model | 5M block, uncached | 5M block, cached | Blocks per $39 (uncached / cached) |
|---|---|---|---|
| Claude Opus 5 | **~$42** | **~$20** | 0.9 / 2.0 |
| Claude Sonnet 5 | **~$17** | **~$8** | 2.3 / 4.9 |
| Claude Haiku 4.5 | **~$8.50** | **~$4** | 4.6 / 9.8 |

Cache writes are priced above input, so a block with heavy cache churn (many new tasks, short
conversations) lands between the two columns. `make usage` reports each engineer's real hit rate.

## 3. Per-engineer cost, including the hosting share

Per-engineer all-in cost is the baseline divided by headcount, plus that engineer's blocks.
Smaller teams pay **less in total but more per head**, because the same fixed baseline is
spread over fewer people.

### Baseline share per engineer

| Headcount | Core baseline (~$550) | Lean baseline (~$400) |
|---|---|---|
| 8 | ~$69 | ~$50 |
| 12 | ~$46 | ~$33 |
| 25 | ~$22 | ~$16 |
| 50 | ~$11 | ~$8 |

### All-in per engineer, one 5M-token block per month, core baseline

| Headcount | Sonnet 5 cached (~$8) | Opus 5 cached (~$20) | Opus 5 uncached (~$42) |
|---|---|---|---|
| 8 | ~$77 | ~$89 | ~$111 |
| 12 | ~$54 | ~$66 | ~$88 |
| 25 | ~$30 | ~$42 | ~$64 |

### Team totals, everyone on one Opus 5 cached block

| Headcount | Core baseline | Tokens | Total / month |
|---|---|---|---|
| 8 | 550 | 160 | **~$710** |
| 12 | 550 | 240 | **~$790** |
| 25 | 550 | 500 | **~$1,050** |

Heavier users simply add blocks: an engineer running 4 blocks of Sonnet 5 cached (20M tokens)
adds ~$32 on top of their baseline share; 4 blocks of Opus 5 cached adds ~$80. The budget
guard caps each engineer at `monthly_usd_budget` regardless of headcount. The default is **$39**, the
list price of a GitHub Copilot Enterprise seat and its monthly AI-credit pool, so the budget
conversation starts from money the organization already spends per engineer.

A team that previously averaged about 1M tokens per engineer per 10 days (about 3M per month)
on a metered assistant is under one block per engineer.

## 4. Tuning to the budget

Levers, in the order they pay off:

1. **Caching on, verified.** Halves the block price. `make smoke` proves it works in the account;
   `make usage` shows each engineer's hit rate. Under 50% almost always means the checkbox is off.
2. **Sonnet 5 as the default tier.** Block price drops 2.5×. Grant `opus` per engineer in
   `engineers.yaml` when the work needs it; spend per tier is visible separately.
3. **Client hygiene.** `cline/.clinerules`, a new task per unit of work, no browser tool by
   default. Fewer tokens per turn and fewer cache writes.
4. **Budget mode.** `usd` (default) rewards caching; `tokens` is simpler to explain but penalizes
   cached traffic; `either` is the conservative cap.
5. **Thresholds and enforcement.** Start with `enforce: true` at the $39 default and read the first month's
   `make usage`. Raise budgets for engineers whose projected spend is consistently over and whose
   cache rate is healthy; they are doing the most work.
6. **Team pooling.** Team-level AWS Budgets alert on the tag total, so an admin can
   `budget-ctl grant` from the team's headroom without touching Terraform.
7. **Gateway cache injection** if any client cannot be trusted to set cache breakpoints.

## 5. Checking the estimate against reality

Cost Explorer, group by tag `team` and `owner` (activate both as cost allocation tags once they
appear in billing). `make usage` totals should track Cost Explorer's Bedrock line within a few
percent; a larger gap means the price table in `engineers.yaml` is stale.
