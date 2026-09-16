# Contributing

Thanks for helping make agency-owned AI coding tooling better.

## Ground rules

- Never commit an AWS account ID, ARN with a real account ID, email address, or credential.
  `terragrunt/live/*` other than `example` is gitignored for this reason.
- Every module must pass `make lint` (terraform fmt, validate, tflint, checkov) and Python
  changes must pass `make test`.
- Keep modules partition-agnostic. Build ARNs from `data.aws_partition`,
  `data.aws_caller_identity`, and `data.aws_region`. Never write `arn:aws:` literally.
- Prefer AWS-native controls over extra services. Every added component must justify its
  place inside a FedRAMP boundary.

## Workflow

1. Fork and branch from `main`.
2. `pre-commit install` and make your change.
3. Run `make lint test`.
4. Open a pull request describing the change and, for infrastructure, the `terragrunt plan`
   output against a sandbox account with account IDs redacted.

## Reporting security issues

See `SECURITY.md`.
