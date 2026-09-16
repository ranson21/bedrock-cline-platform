# Budget Guard

The budget guard turns a per-engineer dollar or token allowance into something the platform
enforces, without a proxy in the request path.

## Data flow

Bedrock invocation log record → CloudWatch Logs subscription → `usage_meter` Lambda:

1. **Dedupe** on `requestId` (DynamoDB conditional put, 3-day TTL). Subscription delivery is
   at-least-once.
2. **Attribute**: `modelId` is the application inference profile ARN. The SSM config (written by
   Terraform from `engineers.yaml` and the profile index) maps ARN → owner, team, tier, base
   model. Fallback is the last segment of `identity.arn`, which for SSO sessions is the userName.
3. **Price**: `input`, `output`, `cacheRead`, `cacheWrite` token counts × the price table in
   `engineers.yaml`. Stored as integer micro-dollars so DynamoDB `ADD` stays exact.
4. **Accumulate** into `USER#<user> / MONTH#<yyyy-mm>`; returns the new totals atomically.
5. **Evaluate** against the effective budget: `defaults` ← engineer entry ← runtime override
   (`budget-ctl grant`). `budget_mode` decides whether percent-used is dollars, tokens or the
   larger of the two.
6. **Alert** once per threshold (50/80/100 by default) on the SNS topic.
7. **Enforce** at 100% when `enforce: true`: tag every profile the engineer owns with
   `budget_state=exhausted`. The engineer permission set carries an explicit Deny on that tag, so
   the next call fails with `AccessDeniedException`. No IAM change, no redeploy.
8. **Cache compliance**: over a rolling window of `cache_window_requests` cacheable requests
   (≥2k context tokens), compute cache-read ÷ (input + cache-read). Below
   `min_cache_hit_rate`, send a nudge with the fix; with `enforce_cache: true`, tag
   `budget_state=cache_disabled`, which the same Deny catches.
9. **Analytics**: index one document per request into the OpenSearch `bedrock-usage` index when the
   observability module's analytics collection is enabled. Best effort.

The `monthly_reset` Lambda runs at 00:05 UTC on the 1st, sets every profile back to `ok`, and
posts last month's summary. It also runs daily to post a digest, and handles `unlock` for
`budget-ctl`.

## Why tags and not a Lambda authorizer

Bedrock has no request-time hook. Tag-based Deny is evaluated by IAM on every call, takes effect
within seconds of the tag write, needs no proxy, and leaves no gap where an engineer is
half-suspended. The only cost is a small lag: the meter sees a request after Bedrock logs it, so
an engineer can overshoot the cap by whatever they spend in the delivery delay (typically under a
minute).

## Operating it

```bash
make usage ENV=dev                                  # who is spending what, cache rates, projections
python tools/budget-ctl/budget_ctl.py --live terragrunt/live/dev status jane.doe
python tools/budget-ctl/budget_ctl.py --live terragrunt/live/dev grant jane.doe --usd 120 --note "release week"
python tools/budget-ctl/budget_ctl.py --live terragrunt/live/dev unlock jane.doe
python tools/budget-ctl/budget_ctl.py --live terragrunt/live/dev lock jane.doe
```

Overrides expire at the end of the month they were granted for. Permanent changes go in
`engineers.yaml`.

## Failure modes

- Meter Lambda errors: usage is not counted for those records (they are not retried after the
  subscription's retry budget). Watch the Lambda error alarm and `make usage` totals against Cost
  Explorer once a week.
- Config drift: the meter caches SSM config for five minutes; new engineers may be unattributed
  for that long. Their usage is still recorded under the session userName.
- Wrong prices: spend is mis-estimated. AWS Budgets on the `team` tag are the independent check.
