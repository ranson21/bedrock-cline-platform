# Onboarding an engineer (admin runbook)

1. Add them to `engineers.yaml`:
   ```yaml
   - username: first.last        # must equal the Identity Center userName
     email: first.last@agency.gov
     team: platform
     models: [sonnet]            # add opus only when justified
   ```
2. Add them to the `bedrock-engineers` group in your IdP (or set `manage_identity_store: true`
   and let Terraform create the user).
3. `make apply ENV=<env>` (only `bedrock-core` and `budget-guard` change).
4. `make profiles ENV=<env>` and send them their ARNs plus `docs/cline-setup.md`.
5. After their first day, run `make usage ENV=<env>` and confirm their cache hit rate is above the
   threshold. If it is not, their caching checkbox is off.

## Offboarding

Remove them from the group (access stops immediately) and from `engineers.yaml` (profiles are
deleted on the next apply). Usage history is retained in DynamoDB.
