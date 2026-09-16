# AWS GovCloud (US) notes

Verified 2026-09 against AWS and Anthropic documentation; re-check before relying on any row.

## Models

| Model | us-gov-west-1 | us-gov-east-1 | How |
|---|---|---|---|
| Claude Opus 5 | in-region | cross-region | `anthropic.claude-opus-5`, or `us-gov.` geo profile |
| Claude Sonnet 5 | in-region | cross-region | `anthropic.claude-sonnet-5` |
| Claude Fable 5 | in-region | cross-region | `anthropic.claude-fable-5` |
| Claude Fable 5.1 | cross-region | cross-region | `us-gov.anthropic.claude-fable-5-1` (set `cross_region: true`) |
| Claude Opus 4.8 | in-region | | |

There is no `global.` endpoint in GovCloud. Opus 5 in GovCloud runs with zero data retention by
default. `make preflight` prints the model IDs your account actually exposes; if they differ from
`model_tiers`, fix the yaml rather than the module.

## Enablement

Accept the Anthropic EULA in a commercial region of the same organization first, then enable
the models in the GovCloud account's Bedrock console. This is a console step.

## Partition-specific behaviors handled by the modules

- All ARNs are built from `data.aws_partition` (`aws-us-gov`).
- Geo inference profile prefix is `us-gov.` (module `bedrock-core` derives it from the partition).
- Service principals are the same as commercial (`bedrock.amazonaws.com`, `lambda.amazonaws.com`);
  the CloudWatch Logs → Lambda permission uses the regional principal
  `logs.<region>.amazonaws.com`, which is valid in both partitions.
- Managed policy ARNs use the partition (`arn:aws-us-gov:iam::aws:policy/...`).
- OpenSearch Serverless, Bedrock Knowledge Bases, Identity Center, Budgets, and Cost Explorer are
  all available in GovCloud. NextGen OpenSearch Serverless collections were not yet supported
  as a Knowledge Base vector store at review time, so the module uses classic collections.

## Cline in GovCloud

Cline's region dropdown accepts custom values; type `us-gov-west-1`. The AWS Profile auth path
uses the standard SDK credential chain, so SSO works unchanged. The `bedrock-mantle`
Messages-API endpoint is also available in us-gov-west-1 for SDK users; Cline uses Converse.

## Compliance references

- Claude in Amazon Bedrock: FedRAMP High and DoD IL4/IL5 (see the Anthropic announcement and
  the AWS Services in Scope page for current status).
- Keep engineer traffic inside the boundary with the `network` module (PrivateLink for
  `bedrock-runtime` and OpenSearch Serverless) and Client VPN, if your policy requires it. Set
  the VPC endpoint URL in Cline's Bedrock settings when on the VPN.
