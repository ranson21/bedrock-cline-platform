# Security and compliance notes

Written for whoever maps this platform onto an SSP or control matrix.

| Control area | Implementation |
|---|---|
| Identification & authentication | IAM Identity Center SSO; no IAM users; no API keys; bearer tokens denied (`bedrock:CallWithBearerToken`); 8-hour engineer sessions, 4-hour admin sessions. |
| Access control | ABAC: principal tag `owner` must equal resource tag `owner`; explicit Deny on `budget_state`. Engineers cannot invoke bare model IDs, other engineers' profiles, or management APIs. |
| Audit & accountability | Bedrock invocation logs (full prompt/response, identity ARN, token counts) to CloudWatch Logs and S3, CMK-encrypted, retention configurable (90 d / 365 d default). CloudTrail for management events. VPC flow logs when the network module is on. |
| Data protection | CMK (rotated) for logs, KB docs, and the vector collection. S3 buckets: versioned, public-access blocked, TLS-only policies. DynamoDB and SNS encrypted. Bedrock does not train on customer data; Opus 5 in GovCloud is ZDR by default. |
| Boundary protection | All components are AWS services in the account. Optional PrivateLink + Client VPN keeps engineer traffic off public endpoints. Gateway, if used, sits on an internal ALB only. |
| Content controls | Optional Bedrock Guardrail (PII anonymization, prompt-attack filter, content filters). Mandatory in gateway mode. |
| Configuration management | All infrastructure in Terraform/Terragrunt; CI runs fmt, validate, tflint, checkov; `allowed_account_ids` guard prevents applying to the wrong account. |
| Resource limits / cost | Per-engineer budgets enforced by the budget guard; team AWS Budgets; throttle alarms. |

## Threat notes

- **Engineer shares their ARN.** Useless without the matching SSO identity; ABAC denies.
- **Engineer disables caching to "get more tokens."** Caching lowers cost, not tokens; the cache
  compliance rule flags or locks it anyway.
- **Compromised laptop.** Blast radius is one engineer's profiles for at most the session length,
  capped by their budget. Revoke by removing group membership; suspend by `budget-ctl lock`.
- **Log exposure.** Invocation logs contain source code and prompts. Only the admin permission set
  and the logging role can read them; the meter Lambda reads only the stream, not S3.
- **Supply chain.** Lambdas use only `boto3`/`botocore` from the runtime. The MCP server pins
  `mcp` and `boto3`. The gateway image should be mirrored into ECR and scanned.
