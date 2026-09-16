# Deploy

## Prerequisites

- Terraform ≥ 1.9, Terragrunt ≥ 0.55, AWS CLI v2, Python 3.10+ with `pip install -r tools/requirements.txt`.
- An AWS account (commercial or GovCloud) where you hold admin credentials for the deploy, ideally
  through an Identity Center admin permission set or a deploy role you set in `account.hcl`.
- **IAM Identity Center enabled** in the account (or delegated from the org management account).
  Create two groups in your IdP or Identity Center: `bedrock-engineers` and `bedrock-admins`
  (names configurable in `engineers.yaml`).
- **Bedrock model access enabled** for the Anthropic models you list in `model_tiers`. In
  GovCloud, accept the Anthropic EULA once in a commercial region (us-east-1 or us-west-2) of the
  same organization, then enable the models in the GovCloud account. Terraform cannot do this.
- OpenSearch Serverless and Bedrock Knowledge Bases available in the target region
  (both are in us-gov-west-1 and us-gov-east-1).

## Steps

```bash
cp -r terragrunt/live/example terragrunt/live/dev
$EDITOR terragrunt/live/dev/account.hcl        # account_id, partition, region, name_prefix
$EDITOR terragrunt/live/dev/engineers.yaml     # engineers, tiers, budgets, prices

make preflight ENV=dev      # fails fast on wrong account, missing models, missing groups
make bootstrap ENV=dev      # state bucket + lock table; local state kept in live/dev/.bootstrap
make plan ENV=dev
make apply ENV=dev          # ~15 minutes; the OpenSearch collection is the slow part
make smoke ENV=dev          # invokes profiles, proves caching, tests KB retrieve
make profiles ENV=dev       # ARNs to hand to each engineer
make sync-docs ENV=dev ARGS="--src ./docs --prefix platform/"   # seed the knowledge base
```

Confirm the SNS email subscriptions that arrive after apply, or alerts will not be delivered.

## Applying to another account

Nothing changes except the `live/<env>/` directory. Copy it, edit `account.hcl`, run the same
targets with `ENV=<env>`. State lives in that account's own bucket.

## Updating engineers

Edit `engineers.yaml` and run `make apply ENV=dev`. New engineers get profiles and the budget
guard picks up the config on its next invocation (it caches for five minutes). Removing an
engineer deletes their profiles; their usage history stays in DynamoDB.

## Terragrunt version note

Terragrunt 0.70+ renamed `run-all` to `run --all`. Set `TG="terragrunt run --all"` style overrides
in the Makefile if you are on the newer CLI, or pin 0.55–0.69.

## Destroy

`make destroy ENV=dev` removes everything except the bootstrap bucket (which has
`prevent_destroy`). Invocation logs in S3 are deleted with the bucket only if you empty it first.
