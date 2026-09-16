# Runbook: add a model tier

1. Confirm the model is enabled in Bedrock and visible in `make preflight` output.
2. Add to `model_tiers` in `engineers.yaml` with the exact model id; set `cross_region: true`
   if it is only reachable via the `us-gov.`/`us.` profile.
3. Add a `prices` entry keyed on a substring of the model id.
4. Grant it to engineers via their `models:` list, then `make apply`.
5. `make smoke` to verify invocation and caching for the new tier.
