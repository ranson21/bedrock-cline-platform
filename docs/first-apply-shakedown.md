# First-apply shakedown checklist

This platform has been validated, linted, and unit-tested, and its preflight has run against a
real account, but the first `terraform apply` in your account is the first time these modules
meet real AWS APIs together. Budget half a day. Work through this list in order in a **dev
account** with two or three test engineers in `engineers.yaml`. Tick every box before onboarding
the team. Report anything that fails as an issue on the repository with the error text and the
module name.

## 0. Before apply

- [ ] You created your environment directory: `cp -r terragrunt/live/example terragrunt/live/dev`,
      and edited `account.hcl` and `engineers.yaml` in the copy (`docs/deploy.md`, step 1).
- [ ] `make preflight ENV=dev` passes completely: partition, region, model tiers resolved,
      Identity Center instance and both groups found, OpenSearch Serverless reachable.
- [ ] You are running as an admin permission set or a deploy role, not root. `aws sts
      get-caller-identity` shows `assumed-role`.
- [ ] `engineers.yaml` has 2–3 real Identity Center userNames, one of them yours, with
      `models: [sonnet]` only. Keep `enforce: true` and the default budget.
- [ ] `make bootstrap ENV=dev` created the state bucket and lock table.
- [ ] `make plan ENV=dev` completes for every unit with no errors. Warnings about deprecated
      arguments are acceptable; record them.

## 1. Apply, unit by unit

Run `make apply ENV=dev`. Terragrunt applies in dependency order. When a unit fails, fix and
re-run; the others are unaffected. Expected sources of first-run friction, in order of
likelihood:

- [ ] **bedrock-core**: application inference profile creation. If it fails with an invalid
      `copy_from`, run `aws bedrock list-foundation-models --by-provider anthropic` and
      `aws bedrock list-inference-profiles` and correct `model_tiers`. Check that profile names
      sanitized from userNames are unique and under 64 characters.
- [ ] **bedrock-core**: invocation logging configuration. If Bedrock refuses the S3 bucket,
      confirm the bucket policy applied before the logging config (it has an explicit
      `depends_on`; re-running usually resolves ordering).
- [ ] **knowledge-base**: OpenSearch index creation. Symptoms: 403 from the collection
      endpoint, or timeout. Cause is almost always the data access policy not yet listing the
      deployer's ARN or not yet propagated. Confirm `aws sts get-caller-identity` ARN matches
      what the policy contains (assumed-role ARNs must be written as the role ARN, not the
      session ARN; the module uses the caller ARN, so a session ARN mismatch here is the
      first thing to check), wait 60 seconds, re-apply.
- [ ] **knowledge-base**: `aws_bedrockagent_knowledge_base` creation. If it complains about
      the index or field mapping, verify the index exists with the three fields and the
      dimension matches the embedding model (Titan v2 = 1024).
- [ ] **identity**: `aws_ssoadmin_instance_access_control_attributes` conflicts if your
      organization already manages ABAC attributes. Set `manage_abac_attributes = false` and
      add the `owner` → `${path:userName}` mapping in the console.
- [ ] **identity**: group lookups fail if display names differ from `engineers.yaml`
      `groups:`. Fix the yaml, not the module.
- [ ] **budget-guard**: the CloudWatch Logs subscription filter fails with an invalid
      principal or permission error. Check the Lambda permission's principal; if
      `logs.<region>.amazonaws.com` is rejected in your partition, change it to
      `logs.amazonaws.com` in `terraform/modules/budget-guard/main.tf` and open an issue.
- [ ] **budget-guard**: `aws_budgets_budget` with a `TagKeyValue` filter may fail before the
      `team` tag has appeared in billing data. Set `enable_team_budgets = false` for the first
      apply and turn it on after the first invoice cycle.
- [ ] **observability**: the analytics collection's data access policy references the
      budget-guard role by name; if `budget-guard` has not applied yet this is fine, the
      policy is just a string. If dashboards complain about the Logs Insights query syntax,
      open the dashboard in the console and paste the query into Logs Insights to see the
      parser error.

## 2. Prove the security model

These are the four claims the whole design rests on. Do not skip them.

- [ ] **Own-profile invoke works.** `aws sso login` as a test engineer, then `make smoke`
      from an admin shell, and separately from the engineer's shell:
      `aws bedrock-runtime converse --model-id <their sonnet ARN> --messages '[{"role":"user","content":[{"text":"OK"}]}]'`
      returns a response.
- [ ] **Someone else's profile is denied.** Same command with another engineer's profile ARN
      returns `AccessDeniedException`.
- [ ] **Bare model ID is denied.** Same command with `--model-id anthropic.claude-sonnet-5`
      (or the `us-gov.` profile id) returns `AccessDeniedException`. This proves the
      `bedrock:InferenceProfileArn` condition is enforced.
- [ ] **Tag-based lock works.** From the admin shell:
      `python tools/budget-ctl/budget_ctl.py --live terragrunt/live/dev lock <user>`; the
      engineer's own-profile call now returns `AccessDeniedException` within a minute.
      `budget_ctl.py ... unlock <user>` restores it. This proves the budget guard's
      enforcement path without waiting for a real overspend.
- [ ] **Bearer tokens are denied.** `aws bedrock-runtime` with `AWS_BEARER_TOKEN_BEDROCK` set
      to any value fails; or simply confirm the engineer permission set's inline policy shows
      the `DenyBearerTokens` statement in the console.

## 3. Prove the metering loop

- [ ] Send five or six messages through Cline as a test engineer.
- [ ] Within two minutes, `make usage ENV=dev` shows the engineer with a non-zero request
      count and USD. If not: check the `<prefix>-budget-meter` Lambda's log group for errors,
      then confirm the subscription filter exists on the invocation log group.
- [ ] The engineer's cache hit rate rises above zero after a few turns of one task. If it
      stays at zero, "Use prompt caching" is off in Cline or the model in that region does not
      support caching. `make smoke` isolates which.
- [ ] Temporarily set `monthly_usd_budget: 0.01` for the test engineer in `engineers.yaml`,
      `make apply`, send one more message, and confirm: an alert email arrives, `make usage`
      shows state `exhausted`, and the engineer is denied. Restore the budget, run
      `budget_ctl.py unlock`, confirm access returns.
- [ ] Invoke the admin Lambda manually with `{"action":"digest"}` and confirm the summary
      email arrives.

## 4. Prove the knowledge base

- [ ] `make sync-docs ENV=dev ARGS="--src ./docs --prefix platform/ --wait"` completes with
      documents indexed and zero failures in the job statistics.
- [ ] `make smoke` returns results for the retrieve step.
- [ ] From Cline, with the MCP server registered, ask a question that only these docs answer
      and see a citation to `platform/...`.
- [ ] Upload one more file to the docs bucket and confirm the ingestion Lambda starts a job
      (check its log group) without being asked.

## 5. Prove operations

- [ ] SNS email subscriptions on both topics (`<prefix>-budget-alerts`,
      `<prefix>-ops-alarms`) are confirmed; unconfirmed subscriptions silently drop alerts.
- [ ] The CloudWatch dashboard `<prefix>-bedrock-usage` renders all six widgets with data.
- [ ] Cost Explorer shows the `owner` and `team` tags as activatable cost allocation tags
      (they appear a day after first use). Activate them.
- [ ] `make plan ENV=dev` after all of the above shows **no changes**. Drift here means a
      resource is being modified outside Terraform, or `ignore_changes` is missing somewhere.
- [ ] `make destroy ENV=dev` on a throwaway account succeeds except for the protected state
      bucket. Knowing teardown works is part of knowing deploy works.

## 6. Record what you learned

- [ ] Every argument or ordering fix you made is either pushed back to the repository or
      filed as an issue.
- [ ] The final GovCloud (or commercial) prices you observed are in `engineers.yaml`.
- [ ] `docs/govcloud-notes.md` gets a line for anything partition-specific you hit.

When every box is ticked, onboard the team using `docs/onboarding.md`. The first week's
`make usage` output is the input to the budget conversation in `docs/cost.md`.
