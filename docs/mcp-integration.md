# Integrating MCP servers with Cline

Cline speaks the Model Context Protocol, so any MCP server becomes a tool the agent can call:
the knowledge base this platform ships, read-only servers for your issue tracker or databases,
or a remote server hosted in the account. This guide covers both transports, how to keep credentials out of
the agent, how to host remote servers inside the boundary, and the governance rules that keep
tool output from eating the token budget.

## How Cline loads servers

Cline reads `cline_mcp_settings.json` (Cline > MCP Servers > Configure). Two shapes:

```jsonc
{
  "mcpServers": {
    "local-server":  { "command": "node", "args": ["/path/dist/index.js"], "env": {}, "disabled": false, "autoApprove": [] },
    "remote-server": { "url": "https://host/mcp", "type": "streamableHttp", "headers": {}, "disabled": false, "autoApprove": [] }
  }
}
```

- **Local (stdio)**: Cline starts the process on the engineer's machine and talks JSON-RPC over
  stdin/stdout. The process runs as the engineer, with the engineer's credentials and network.
- **Remote (Streamable HTTP, or legacy SSE)**: Cline connects to a URL. The server runs
  somewhere else and needs its own authentication.

`autoApprove` lists tool names Cline may call without asking. Everything else prompts.
`cline/cline_mcp_settings.json` is a complete example with all three servers below.

## Local servers

### The knowledge base (ships with this platform)

`tools/mcp-kb-server`. Uses the engineer's SSO profile; access is the `bedrock:Retrieve`
statement in the engineer permission set. No secret. See `docs/cline-setup.md`.

### Read-only servers for your issue tracker and databases

The most useful local servers give the agent read access to the systems engineers already
consult: the issue tracker, a database, a CI system, an internal wiki. Choose or build them on
one principle, the same one this platform uses for the knowledge base: **the server owns the
credential, the model never sees it, and the server is architecturally incapable of writes.**
For an issue tracker that means an HTTP client that only implements GET. For a database it
means opening every session read-only at the protocol level (Postgres:
`default_transaction_read_only=on`), sending one statement per request, and connecting as a
role with `SELECT` grants only. A validator that rejects write keywords is a useful extra layer
but never the boundary.

Such servers are typically a single Node or Python process configured entirely by environment
variables, for example `ISSUE_TRACKER_URL` and `ISSUE_TRACKER_TOKEN`, or the standard libpq
variables `PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER`, `PGPASSWORD`, `PGSSLMODE`. Their READMEs
usually suggest a `.env` file. **Do not use a `.env` file or put tokens in
`cline_mcp_settings.json` here.** Use the wrapper below instead.

### Credentials: Secrets Manager, resolved at launch

`cline/mcp/run-with-secrets.sh` fetches a JSON secret with the engineer's SSO profile, exports
its keys as environment variables, and `exec`s the server. Nothing is written to disk and the
settings file holds only a secret id.

Platform admin, once per server:

```bash
aws secretsmanager create-secret --name <prefix>/mcp/issue-tracker \
  --secret-string '{"ISSUE_TRACKER_URL":"https://issues.example.internal","ISSUE_TRACKER_TOKEN":"<read-only token>"}'
aws secretsmanager create-secret --name <prefix>/mcp/database-dev \
  --secret-string '{"PGHOST":"dev-db.example.internal","PGPORT":"5432","PGDATABASE":"appdb","PGUSER":"readonly_user","PGPASSWORD":"<pw>","PGSSLMODE":"require"}'
```

The engineer permission set grants `secretsmanager:GetSecretValue` on `<prefix>/mcp/*`
(shared, read-only service credentials) and on `<prefix>/mcp/users/<their userName>/*`
(personal credentials, for example an issue-tracker token tied to their own account). Database
roles must have `SELECT` grants only; tracker accounts should be read-only service accounts.

Engineer, in `cline_mcp_settings.json`:

```jsonc
"issue-tracker": {
  "command": "/path/to/bedrock-cline-platform/cline/mcp/run-with-secrets.sh",
  "args": ["<prefix>/mcp/issue-tracker", "node", "/path/to/issue-tracker-mcp/dist/index.js"],
  "env": { "AWS_PROFILE": "bedrock", "AWS_REGION": "<region>" }
}
```

Reachability: a database in a private subnet is only reachable from a laptop over the Client
VPN from the `network` module, or a bastion. A SaaS tracker is reachable from anywhere; a
self-hosted one inside the network needs the same VPN.

## Remote servers

Use a remote server when the tool needs network access the laptop lacks, a credential no
engineer should hold at all, or shared state. Host it **inside the account**, never on a
third-party MCP hosting service, so the boundary argument in the README stays true.

### Hosting pattern

Same shape as the `gateway` module: a container on ECS Fargate in the `network` module's
private subnets, an internal ALB with an ACM certificate, reachable over Client VPN or from
inside the VPC. Copy `terraform/modules/gateway`, replace the image, port and health-check
path, drop the Bedrock permissions, and give the task role exactly the access the server needs
(a Secrets Manager secret, a database security group, an internal API). Log to CloudWatch.

### Authentication

Cline supports OAuth for remote servers and static headers. Pick one:

1. **OAuth (preferred).** The server implements the MCP authorization flow against your IdP
   (Identity Center exposes OIDC through a customer-managed application, or through Cognito
   federated to it). Cline opens the browser login once and refreshes tokens itself. Every
   request carries the engineer's identity, so audit and per-user authorization work.
2. **Bridge with `mcp-remote`.** If a server supports OAuth but Cline's built-in flow does not
   work with your IdP, run it as a local server: `"command": "npx", "args": ["mcp-remote",
   "https://host/mcp"]`. The bridge handles OAuth and speaks stdio to Cline.
3. **Static bearer header, last resort.** ALB OIDC authentication cannot be used because Cline
   does not run a browser redirect for plain HTTP servers, so a static token in `headers` is the
   only option. Keep such tokens per engineer, short-lived, and issued from Secrets Manager
   under `<prefix>/mcp/users/<userName>/`, read by a small wrapper the same way the local
   runner does.

Network placement is the other half of authentication: an internal ALB plus VPN means an
unauthenticated request cannot even reach the server.

## Governance

- **Registry.** `cline/mcp/registry.md` lists approved servers, owner, what they reach, and
  whether they can write. Engineers register only servers in the registry. Add a row in a pull
  request before rollout.
- **Read-only by default.** Prefer servers that cannot write. A write-capable server needs a
  justification in the registry row, `autoApprove` empty, and its own audit log.
- **Auto-approve only pure reads with bounded output.** `describe_table` yes; `run_query` no,
  because a `SELECT *` on a large table is both a data exposure and a token bill.
- **Tool output is untrusted input.** Ticket text and database rows can contain prompt
  injection. `cline/.clinerules` tells the agent to treat MCP results as data, never as
  instructions. Prefer servers that also redact credential-shaped strings in their output.
- **Token cost.** Every tool result is re-sent as input on every following turn of the task
  (cached, but not free). Keep search limits small, ask for specific columns, and start a new
  task after a large investigation. `make usage` shows who is
  paying for large contexts.
- **Secrets.** Never in `cline_mcp_settings.json`, `.env` files, or repos. Secrets Manager under
  `<prefix>/mcp/`, rotated like any other service credential, read-only principals only.
- **Logging.** Local servers log to stderr, which Cline shows in its MCP panel. Remote servers
  log to CloudWatch with the caller identity.

## Adding a new server, checklist

1. Confirm it is read-only or document why not.
2. Decide local vs remote by where the credential and the network access should live.
3. Create the secret under `<prefix>/mcp/` (shared) or `<prefix>/mcp/users/<user>/` (personal).
4. Add the registry row and the `cline_mcp_settings.json` snippet to this repo.
5. Test with one engineer; check `make usage` after a day for context growth.
6. Announce it with the auto-approve list and the token-hygiene note.
