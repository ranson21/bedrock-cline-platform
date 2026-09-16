# mcp-kb-server

Local MCP server that gives Cline a `search_knowledge_base` tool backed by the Bedrock
Knowledge Base this platform deploys. It uses the engineer's own SSO credentials; nothing
is proxied.

```bash
pipx install ./tools/mcp-kb-server        # or: pip install ./tools/mcp-kb-server
```

Register it in Cline (MCP Servers > Configure) with `cline/cline_mcp_settings.json` as the
template, filling in `KB_ID`, `AWS_PROFILE` and `AWS_REGION`.
