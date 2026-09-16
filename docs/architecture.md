# Architecture

## Request path

1. The engineer runs `aws sso login --profile bedrock`. IAM Identity Center issues short-lived
   credentials for the `<prefix>-BedrockEngineer` permission set. The session principal carries
   the tag `owner=<userName>` through ABAC attribute mapping.
2. Cline (AWS Bedrock provider, AWS Profile auth) signs Converse/InvokeModel calls with those
   credentials and targets the engineer's **application inference profile ARN**.
3. IAM allows the call only if the profile's `owner` tag equals the principal's `owner` tag, the
   profile is not tagged `budget_state=exhausted|cache_disabled`, and the underlying model is
   reached through that profile. Bearer tokens are denied.
4. Bedrock serves the request from Claude in-region (or via the `us-gov.`/`us.` geo profile for
   cross-region tiers) and writes a `ModelInvocationLog` record to CloudWatch Logs and S3,
   encrypted with the customer-managed key.
5. A subscription filter streams each record to the **usage meter** Lambda, which attributes it to
   the engineer, prices it, updates DynamoDB, alerts, and enforces the budget by tagging the
   profile. Optionally it indexes the record into the OpenSearch analytics collection.
6. Cline's MCP client runs `mcp-kb-server` locally, which calls `bedrock:Retrieve` on the
   Knowledge Base. The KB service role reads vectors from the OpenSearch Serverless collection.

```
engineer laptop                      AWS account (aws | aws-us-gov)
┌───────────────────┐   SigV4      ┌───────────────────────────────────────────────────────┐
│ VS Code + Cline   │─────────────▶│ Bedrock: application-inference-profile/<owner>/<tier> │
│  AWS profile SSO  │              │   └─ foundation-model / geo inference profile         │
│  MCP: kb-server ──┼──Retrieve──▶ │ Bedrock Knowledge Base ─▶ OpenSearch Serverless (KB)  │
└───────────────────┘              │        ▲ ingestion Lambda ◀─ S3 docs bucket           │
                                   │ invocation logs ─▶ CloudWatch Logs ─▶ meter Lambda    │
                                   │        └─▶ S3 (CMK)          ├─▶ DynamoDB (budgets)   │
                                   │                              ├─▶ SNS alerts           │
                                   │                              ├─▶ tag profile          │
                                   │                              └─▶ OpenSearch (usage)   │
                                   │ CloudWatch dashboard · Budgets · optional VPC/gateway │
                                   └───────────────────────────────────────────────────────┘
```

## Modules and dependency order

| Order | Module | Creates | Depends on |
|---|---|---|---|
| 0 | `bootstrap` | state bucket, lock table, KMS | nothing (local state) |
| 1 | `bedrock-core` | invocation logging, KMS, S3, per-engineer inference profiles, guardrail | — |
| 2 | `knowledge-base` | KMS, docs bucket, OpenSearch Serverless vector collection + index, KB, data source, ingestion Lambda | — |
| 3 | `observability` | CloudWatch dashboard, alarms, ops SNS topic, optional analytics collection | bedrock-core |
| 4 | `budget-guard` | DynamoDB, SSM config, alerts topic, meter + admin Lambdas, team Budgets | bedrock-core, observability |
| 5 | `identity` | Identity Center permission sets, ABAC mapping, group assignments | bedrock-core, knowledge-base, budget-guard |
| opt | `network` | VPC, PrivateLink endpoints, flow logs, Client VPN | — |
| opt | `gateway` | LiteLLM on Fargate, internal ALB, secrets, optional Postgres | network, bedrock-core |

## Why application inference profiles

They are the only Bedrock primitive that is simultaneously an IAM resource (so ABAC can scope
access), a taggable cost-allocation object (so Cost Explorer can split spend by engineer and
team), and a runtime-mutable object (so tagging can suspend access without touching IAM).
Cline supports them natively through its "Custom" model option.

## Why not a proxy by default

A proxy adds a component inside the authorization boundary, a place where prompts are
decrypted, and an operational dependency for every engineer. The direct path uses only
AWS-managed services and IAM. The gateway module exists for the cases IAM cannot express:
per-request rate limits, server-side cache injection, mandatory guardrails, and
OpenAI-compatible clients.
