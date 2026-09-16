#!/usr/bin/env bash
# Start a local MCP server with its credentials pulled from AWS Secrets Manager at launch,
# using the engineer's SSO profile. Nothing secret is written to disk or to Cline's settings.
#
# Usage in cline_mcp_settings.json:
#   "command": "/path/to/run-with-secrets.sh",
#   "args": ["<secret-id>", "node", "/path/to/server/dist/index.js"],
#   "env": { "AWS_PROFILE": "bedrock", "AWS_REGION": "us-gov-west-1" }
#
# The secret must be a JSON object of environment variables, e.g.
#   {"JIRA_BASE_URL":"https://jira.example.internal","JIRA_TOKEN":"..."}
set -euo pipefail
SECRET_ID="${1:?secret id}"; shift
JSON="$(aws secretsmanager get-secret-value --secret-id "$SECRET_ID" --query SecretString --output text)"
while IFS='=' read -r k v; do export "$k=$v"; done < <(printf '%s' "$JSON" | python3 -c 'import json,sys; [print(f"{k}={v}") for k,v in json.load(sys.stdin).items()]')
exec "$@"
