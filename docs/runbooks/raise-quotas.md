# Runbook: Bedrock throttling / raise quotas

Symptom: `ThrottlingException` in Cline, the `<prefix>-bedrock-throttles` alarm fires.

1. Check which model: CloudWatch dashboard, "Requests by model / profile".
2. Service Quotas console → Amazon Bedrock → search the model name → request an increase for
   "tokens per minute" and "requests per minute" for that model in the region. GovCloud quotas
   are requested in the GovCloud console.
3. Interim: move the affected tier to `cross_region: true` in `engineers.yaml` (geo profile
   spreads load across GovCloud regions) and `make apply`.
4. If a single engineer is the source, `make usage` will show it; talk to them about task hygiene
   or lower their budget.
