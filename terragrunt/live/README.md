# live/

One directory per deployment target (account, or environment within an account). The
directory name is the `ENV` you pass to `make`. Only `example/` is committed.

```bash
cp -r terragrunt/live/example terragrunt/live/dev
$EDITOR terragrunt/live/dev/account.hcl      # account id, partition, region, name prefix
$EDITOR terragrunt/live/dev/engineers.yaml   # engineers, tiers, budgets, prices, group names
make preflight ENV=dev
```

Each unit subdirectory (`identity/`, `bedrock-core/`, ...) holds a `terragrunt.hcl` that points
at a module and passes inputs from `account.hcl` and `engineers.yaml`. You normally edit only
the two config files; edit a unit's `terragrunt.hcl` to change module variables such as
`enable_guardrail` or `standby_replicas`.

Directories other than `example/` are gitignored so real account ids never land in git. In a
private fork, remove that ignore rule and version your environment directories.
