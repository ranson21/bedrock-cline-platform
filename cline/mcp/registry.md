# Approved MCP servers

Every server engineers may register in Cline, with who owns it and what it can reach. Add a
row before rolling a server out; `docs/mcp-integration.md` explains the columns.

| Name | Transport | Source | Reaches | Write-capable | Secret id | Auto-approve |
|---|---|---|---|---|---|---|
| team-knowledge-base | local stdio | `tools/mcp-kb-server` (this repo) | Bedrock Knowledge Base | no | none (SSO) | all tools |
| issue-tracker | local stdio | `<repo or package>` | issue tracker REST, GET only | no | `<prefix>/mcp/issue-tracker` | read tools with bounded output |
| database-dev | local stdio | `<repo or package>` | dev database, read-only session | no | `<prefix>/mcp/database-dev` | schema tools only, never raw query |
