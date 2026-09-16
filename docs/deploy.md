# Deploy

## Prerequisites

- Terraform ≥ 1.9, Terragrunt ≥ 0.55, AWS CLI v2, Python 3.10+ with `pip install -r tools/requirements.txt`.
- An AWS account (commercial or GovCloud) where you hold admin credentials for the deploy, ideally
  through an Identity Center admin permission set or a deploy role you set in `account.hcl`.
- **IAM Identity Center enabled** in the account (or delegated from the org management account)
  with two groups, `bedrock-engineers` and `bedrock-admins` (names configurable in
  `engineers.yaml`). Not enabled yet? `docs/runbooks/enable-identity-center.md`.
- **Bedrock model access enabled** for the Anthropic models you list in `model_tiers`. In
  GovCloud, accept the Anthropic EULA once in a commercial region (us-east-1 or us-west-2) of the
  same organization, then enable the models in the GovCloud account. Terraform cannot do this.
- OpenSearch Serverless and Bedrock Knowledge Bases available in the target region
  (both are in us-gov-west-1 and us-gov-east-1).

## Step 1: create your environment directory

Every deployment target (an account, or an environment inside an account) is a directory under
`terragrunt/live/`. The repository ships only `terragrunt/live/example/`; you copy it, and the
copy's name becomes the `ENV` you pass to every `make` target.

```bash
cp -r terragrunt/live/example terragrunt/live/dev     # "dev" is the ENV name; pick anything
```

Then edit the two files in the copy:

- `terragrunt/live/dev/account.hcl` — `account_id`, `partition` (`aws` or `aws-us-gov`),
  `region`, `environment`, `name_prefix`, and optionally `deploy_role_arn`.
- `terragrunt/live/dev/engineers.yaml` — engineers, teams, model tiers, budgets, prices, and
  the Identity Center group names.

Everything under `terragrunt/live/` except `example/` is gitignored, so your account id never
lands in this repository. If you run from a private fork, un-ignore your directory there (see
"Running from a private fork" below). One directory per target: `live/dev`, `live/prod`,
`live/agency-sandbox`, each with its own state bucket.

## Step 2: deploy

```bash
make preflight ENV=dev      # fails fast on wrong account, missing models, missing groups
make bootstrap ENV=dev      # state bucket + lock table; local state kept in live/dev/.bootstrap
make plan ENV=dev
make apply ENV=dev          # ~15 minutes; the OpenSearch collection is the slow part
make smoke ENV=dev          # invokes profiles, proves caching, tests KB retrieve
make profiles ENV=dev       # ARNs to hand to each engineer
make sync-docs ENV=dev ARGS="--src ./docs --prefix platform/"   # seed the knowledge base
```

`ENV` defaults to `dev` if you omit it.

Confirm the SNS email subscriptions that arrive after apply, or alerts will not be delivered.

**First deployment in a new account?** Work through `docs/first-apply-shakedown.md` before
onboarding anyone. It lists the likely first-run friction per module and the security and
metering proofs to run.

The knowledge base index is empty after apply. Seed it with the agent: `docs/knowledge-base-seeding.md`.

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

## Running from a private fork

Most teams clone this repository into a private git host to collaborate with their platform
or DevOps group and keep the public version as the upstream. Suggested shape:

- Keep the public repo as `upstream` and pull improvements with `git fetch upstream && git merge
  upstream/main`. Put local changes in modules behind variables where possible so merges stay
  clean, and send generic fixes back upstream.
- Un-ignore your environment directory in the private fork (`terragrunt/live/<env>/` is
  gitignored here so account ids never reach the public repo). In a private repo it is fine
  and useful to version `account.hcl` and `engineers.yaml`.
- Keep `prices:` and `docs/cost.md` localized to your rate card in the fork; keep them at list
  price upstream.
- Run the same CI workflow; it needs no secrets and no AWS access.
