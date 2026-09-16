# Approved MCP servers

Every server engineers may register in Cline, with who owns it and what it can reach. Add a
row before rolling a server out; `docs/mcp-integration.md` explains the columns.

| Name | Transport | Source | Reaches | Write-capable | Secret id | Auto-approve |
|---|---|---|---|---|---|---|
| team-knowledge-base | local stdio | `tools/mcp-kb-server` (this repo) | Bedrock Knowledge Base | no | none (SSO) | all tools |
| jira | local stdio | github.com/ranson21/jira-readonly-mcp | Jira REST, GET only | no | `<prefix>/mcp/jira` | all tools |
| postgres | local stdio | github.com/ranson21/postgres-readonly-mcp | Postgres, read-only session | no | `<prefix>/mcp/postgres-<env>` | `list_tables`, `describe_table` only |
