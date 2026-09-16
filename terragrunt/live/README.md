# live/

One directory per target account or environment. Copy `example/` and edit:

- `account.hcl` — account id, partition, region, name prefix, optional deploy role.
- `engineers.yaml` — engineers, teams, model tiers, budgets, and the price table.

Directories other than `example/` are gitignored so real account IDs never land in git.
If you want to version your environment config, do it in a private repo that vendors this one.
