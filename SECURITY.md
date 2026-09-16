# Security policy

## Reporting a vulnerability

Open a private security advisory on the repository, or email the maintainers listed in
`CODEOWNERS` if present. Do not open a public issue for a vulnerability in the infrastructure
code, the Lambda functions, or the MCP server.

## Scope

- Terraform modules under `terraform/modules`
- Lambda code under `terraform/modules/*/lambda`
- Tools under `tools/`

## Design notes for reviewers

- Engineers hold no long-lived credentials. Access is Identity Center SSO with short sessions.
- Bearer-token authentication to Bedrock is denied by policy.
- Invocation logs contain prompts and completions and are treated as sensitive. They are
  encrypted with a customer-managed KMS key and access is limited to the admin permission set
  and the budget guard Lambda, which reads only token counts and identity.
- The MCP knowledge-base server runs locally on the engineer's machine using their own
  credentials. It has no network listeners.
