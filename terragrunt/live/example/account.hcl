# Copy this directory to live/<env>/ and fill in your values.
# Nothing in the modules is hardcoded to an account or partition.
locals {
  account_id  = "000000000000"  # target AWS account id
  partition   = "aws-us-gov"    # "aws" for commercial, "aws-us-gov" for GovCloud
  region      = "us-gov-west-1" # Bedrock + OpenSearch Serverless must both be available here
  environment = "dev"
  name_prefix = "bcp" # short, lowercase; used in every resource name

  # Optional: role Terragrunt assumes in the target account. Leave empty to use
  # whatever credentials are in your shell (for example an Identity Center admin profile).
  deploy_role_arn = ""

  extra_tags = {
    Owner = "platform-team"
  }
}
