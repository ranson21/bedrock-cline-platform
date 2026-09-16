# Cost model and budget tuning

Last reviewed 2026-09. All figures are public AWS list prices or estimates derived from them,
rounded. They are not a quote. **When you localize this file, keep it free of your account's
actual spend, negotiated discounts (EDP/PPA), and account identifiers** if the repo stays public.

The model is deliberately simple:

```
monthly cost  =  baseline infrastructure  +  Σ engineers ( token blocks used × price per 5M-token block )
per-engineer  =  baseline ÷ headcount      +  blocks × block price
```

## 1. Baseline infrastructure (fixed, excludes model tokens)

| Component | Sizing | USD / month |
|---|---|---|
| OpenSearch Serverless, KB vector collection | 2 OCU, standby DISABLED | ~350 |
| OpenSearch Serverless, usage analytics collection | shares account OCU pool, plus storage | ~0–200 |
| Bedrock invocation logging (CloudWatch Logs + S3, CMK) | 25 engineers, heavy use | ~60–120 |
| Budget Guard (Lambda, DynamoDB, SNS, SSM, EventBridge) | pay-per-request | ~5 |
| KMS keys (3), dashboard, alarms | | ~8 |
| **Core baseline** | | **~425–685, plan on ~550** |
| Optional: network (10 interface endpoints, flow logs, no NAT) | | +~90 |
| Optional: Client VPN (endpoint + 2 subnet associations, before connection-hours) | | +~150 |
| Optional: gateway (2× Fargate 1 vCPU / 2 GB, internal ALB) | | +~100 |
| Optional: gateway database (db.t4g.micro Postgres) | | +~15 |
| **Everything on** | | **~800–1050** |

GovCloud runs roughly 15–25% above commercial list; the ranges lean high already. Enabling
`standby_replicas = ENABLED` doubles that collection's OCU line.

Baseline per engineer at 25 engineers: **~$22/month core**, ~$36 with every option on.

## 2. Price per 5M-token block

Bedrock list prices per 1M tokens, GovCloud estimated at +20% over global. Confirm at
https://aws.amazon.com/bedrock/pricing/ and keep `prices:` in `engineers.yaml` in sync.

| Model | Input | Cache write | Cache read | Output |
|---|---|---|---|---|
| Claude Opus 5 | ~6.00 | ~7.50 | ~0.60 | ~30.00 |
| Claude Sonnet 5 | ~2.40 | ~3.00 | ~0.24 | ~12.00 |
| Claude Haiku 4.5 | ~1.20 | ~1.50 | ~0.12 | ~6.00 |

What one **5M-token block** costs depends on how much of it is cached. Two reference mixes:

- **Uncached**: 90% input, 10% output. What you pay if "Use prompt caching" is off.
- **Cached**: 10% fresh input, 80% cache read, 10% output. Typical for Cline with caching on.

| Model | 5M block, uncached | 5M block, cached | Blocks per $48 (uncached / cached) |
|---|---|---|---|
| Claude Opus 5 | **~$42** | **~$20** | 1.1 / 2.4 |
| Claude Sonnet 5 | **~$17** | **~$8** | 2.8 / 6.0 |
| Claude Haiku 4.5 | **~$8.50** | **~$4** | 5.6 / 12 |

Cache writes are priced above input, so a block with heavy cache churn (many new tasks, short
conversations) lands between the two columns. `make usage` reports each engineer's real hit rate.

## 3. Per-engineer cost after the baseline

Add the baseline share to the blocks consumed. At 25 engineers on the core baseline ($22 each):

| Engineer profile | Blocks / month | Model, mix | Tokens | Cost |
|---|---|---|---|---|
| Light | 1 | Sonnet 5, cached | 5M | 22 + 8 = **~$30** |
| Typical (the default budget) | 1 | Opus 5, uncached | 5M | 22 + 42 = **~$64** |
| Typical, caching on | 1 | Opus 5, cached | 5M | 22 + 20 = **~$42** |
| Heavy agentic | 4 | Sonnet 5, cached | 20M | 22 + 32 = **~$54** |
| Heavy agentic | 4 | Opus 5, cached | 20M | 22 + 80 = **~$102** |
| Very heavy | 10 | Opus 5, cached | 50M | 22 + 200 = **~$222** |

Team of 25, everyone at the "typical, caching on" row: 550 + 25 × 20 = **~$1,050/month**.
Team of 25 at "heavy agentic, Sonnet cached": 550 + 25 × 32 = **~$1,350/month**.

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
5. **Thresholds and enforcement.** Start with `enforce: true` at $48 and read the first month's
   `make usage`. Raise budgets for engineers whose projected spend is consistently over and whose
   cache rate is healthy; they are doing the most work.
6. **Team pooling.** Team-level AWS Budgets alert on the tag total, so an admin can
   `budget-ctl grant` from the team's headroom without touching Terraform.
7. **Gateway cache injection** if any client cannot be trusted to set cache breakpoints.

## 5. Checking the estimate against reality

Cost Explorer, group by tag `team` and `owner` (activate both as cost allocation tags once they
appear in billing). `make usage` totals should track Cost Explorer's Bedrock line within a few
percent; a larger gap means the price table in `engineers.yaml` is stale.
