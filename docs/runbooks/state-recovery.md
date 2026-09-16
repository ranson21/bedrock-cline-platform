# Runbook: Terraform state recovery

State lives in `<prefix>-tfstate-<account>-<region>`, versioned. Locks in `<prefix>-tflock`.

- **Stuck lock:** `terragrunt force-unlock <id>` from the unit directory, after confirming nobody
  is applying.
- **Corrupt state:** restore the previous object version in S3 (console → bucket → object →
  versions), then `terragrunt plan` to confirm no drift.
- **Lost bootstrap state:** the bootstrap bucket has `prevent_destroy`; re-run
  `make bootstrap` in a clean directory and `terraform import` the bucket and table if you need
  to manage them again.
