# Runbook: enable IAM Identity Center and create the groups

`make preflight` reports `IAM Identity Center is not enabled in this account/region` when the
`identity` module has nothing to attach permission sets to. Identity Center is free. Enabling
it and creating two groups is a one-time console task that takes about fifteen minutes. This
applies identically in the commercial and GovCloud partitions.

## 1. Decide the instance type

| Situation | Choose | Notes |
|---|---|---|
| The account belongs to an AWS Organization (typical for agencies and companies) | **Organization instance**, enabled from the management account or a delegated administrator | One Identity Center for every account in the org. Permission sets are assigned per account. Recommended. |
| Standalone account, no organization (a personal dev account) | **Account instance** | Scoped to this one account. Enough for this platform. Can be converted later by enabling an organization instance. |

Identity Center lives in **one home region per organization**. Pick the region where you will
deploy (`account.hcl` → `region`), because the `identity` module looks the instance up in the
provider's region. In GovCloud that is `us-gov-west-1` or `us-gov-east-1`. If your
organization already has an instance in a different region, that is fine: set
`identity_center_region` to it (see step 5) rather than creating a second instance.

## 2. Enable it

Console → IAM Identity Center → **Enable**.

- Organization instance: you must be signed in to the management account (or the delegated
  admin). Choose "Enable with AWS Organizations".
- Account instance: choose "Enable in this account only".

Do not use root credentials for this or anything else in the platform; use an IAM user or role
with administrator access for the enablement, then switch to a permission set (step 6).

## 3. Choose the identity source

Identity Center → Settings → Identity source:

- **Identity Center directory** (default): users and groups live in Identity Center. Simplest.
  You may let Terraform create the users by setting `manage_identity_store = true` in the
  `identity` unit; Terraform then creates users from `engineers.yaml` and adds them to the
  engineers group.
- **External identity provider** (Okta, Entra ID, Ping, ADFS, or an agency IdP over SAML with
  SCIM provisioning): users and groups are pushed from the IdP. Keep
  `manage_identity_store = false`. Create the two groups in the IdP and let SCIM sync them.
  Confirm the IdP sends `userName` as the value engineers will type in `engineers.yaml`; the
  ABAC policy compares it byte-for-byte with the `owner` tag on inference profiles.

## 4. Create the groups

Identity Center → Groups → Create group, twice. The names must match `groups:` in
`engineers.yaml` (defaults below):

| Group | Purpose | Members |
|---|---|---|
| `bedrock-engineers` | gets the `<prefix>-BedrockEngineer` permission set | every engineer using Cline |
| `bedrock-admins` | gets the `<prefix>-BedrockAdmin` permission set | platform operators |

With an external IdP, create them there and wait for SCIM to sync (Identity Center → Groups
should list them within a few minutes). Add at least yourself to `bedrock-admins`.

Add users to `bedrock-engineers` as you add them to `engineers.yaml`; group membership grants
the permission set, `engineers.yaml` creates their profiles and budget. Both are needed.

## 5. Point the platform at it

Nothing to configure when the instance is in the deployment region. If it is elsewhere, add a
provider alias for the Identity Center region in the `identity` unit:

```hcl
# terragrunt/live/<env>/identity/terragrunt.hcl
generate "sso_provider" {
  path      = "provider_sso.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOP
provider "aws" {
  alias  = "sso"
  region = "<identity-center-home-region>"
  allowed_account_ids = ["<account-id>"]
}
EOP
}
```

and set `provider = aws.sso` on the `aws_ssoadmin_*` and `aws_identitystore_*` resources in
`terraform/modules/identity/main.tf`. Permission-set assignments still target the deployment
account.

## 6. Verify

```bash
make preflight ENV=<env>
```

Expect `Identity Center instance found`, `group bedrock-engineers exists`, and
`group bedrock-admins exists`. Then continue with `make bootstrap` and `make apply`.

After `make apply`, sign in through the access portal (Identity Center → Settings → AWS access
portal URL), confirm the two permission sets appear for the account, and use the admin one for
all further Terraform runs by putting it in `~/.aws/config`:

```ini
[sso-session agency]
sso_start_url = https://<portal>/start
sso_region = <identity-center-home-region>
sso_registration_scopes = sso:account:access

[profile bcp-admin]
sso_session = agency
sso_account_id = <account-id>
sso_role_name = <prefix>-BedrockAdmin
region = <deployment-region>
```

## 7. ABAC attribute mapping

The `identity` module sets the instance's access-control attribute `owner` →
`${path:userName}` (`manage_abac_attributes = true`). If your organization already manages
attributes for access control on the instance, set it to `false` and add the `owner` mapping
yourself under Identity Center → Settings → Attributes for access control. Without it every
engineer's invoke call is denied, because the policy compares `aws:PrincipalTag/owner` to the
profile's `owner` tag.

## Troubleshooting

- **`preflight` still says not enabled after enabling.** Wrong region. Identity Center is
  regional; run `aws sso-admin list-instances --region <home-region>`.
- **Groups not found with an external IdP.** SCIM has not synced, or the group is not assigned
  to the Identity Center application in the IdP. Check Identity Center → Settings → Identity
  source → SCIM sync status.
- **`aws sso login` succeeds but Bedrock calls are denied.** The permission set is attached,
  but ABAC is not: check step 7, and check that the userName equals the `owner` tag on the
  profile (`aws bedrock list-tags-for-resource --resource-arn <profile-arn>`).
- **Root credentials.** Identity Center cannot be used by root, and the modules assume a
  non-root deployer. Create an IAM user or role for the enablement step, then move to the admin
  permission set.
