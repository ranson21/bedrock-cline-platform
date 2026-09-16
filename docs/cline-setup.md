# Cline setup for engineers

Time: about ten minutes. You need: VS Code, the AWS CLI v2, Python 3.10+, and the values your
admin sent you (account id, region, Identity Center portal URL, your inference profile ARNs,
knowledge base id).

## 1. Install

- VS Code extension: search "Cline" in the marketplace (publisher saoudrizwan) and install.
- AWS CLI v2: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html
- Knowledge-base tool: `pipx install <repo>/tools/mcp-kb-server` (or `pip install --user`).

## 2. Configure SSO

Append the block from `cline/aws-config.example` to `~/.aws/config`, filling in the portal URL,
account id and region. Then:

```bash
aws sso login --profile bedrock
aws sts get-caller-identity --profile bedrock    # should show AWSReservedSSO_<prefix>-BedrockEngineer_.../<you>
```

Sessions last 8 hours by default. Re-run the login command when Cline reports expired credentials.

## 3. Configure Cline

Open Cline, click the gear, and enter the values from `cline/settings.example.md`:

1. API Provider **AWS Bedrock**, authentication **AWS Profile**, profile name `bedrock`.
2. AWS Region: your region (type `us-gov-west-1` if it is not in the dropdown).
3. Tick **Use prompt caching**. This is required. Without it your budget lasts a quarter as long
   and the platform will nudge, and may suspend, your access.
4. Model: choose **Custom** and paste your application inference profile ARN into **Model ID**.
   Pick the matching **Base Inference Model**.
5. Do the same for Plan mode and Act mode. Use your sonnet ARN for Plan mode.
6. Leave "Use cross-region inference" off unless your admin told you your tier is cross-region.

Send a message. If you see an `AccessDeniedException`, the ARN is not yours, your session
expired, or your budget is exhausted; see the FAQ below.

## 4. Register the knowledge base tool

Cline > MCP Servers > Configure MCP Servers. Paste `cline/cline_mcp_settings.json`, set `KB_ID`,
`AWS_PROFILE` and `AWS_REGION`. Ask Cline "what does the knowledge base say about deploys?" to test.

## 5. Add the rules file

Copy `cline/.clinerules` into the root of each repo you work in. It keeps Cline terse and
context-efficient, which is what makes the budget go far.

## Recommended Cline settings for long agentic runs

- Auto-approve: read files, edit files, execute safe commands, use MCP servers. Keep "execute all
  commands" off in shared repos.
- Checkpoints on. They are local git snapshots and cost no tokens.
- Enable "Adaptive Thinking".
- Start a new task for each unrelated piece of work. Long tasks accumulate context that is re-sent
  every turn; caching makes that cheap, but a fresh task is free.

## FAQ

**AccessDeniedException: budget_state.** You have hit your monthly budget or caching was off.
Check the alert email; ask an admin for `budget-ctl grant` if you need more this month.

**Why does the token count in Cline keep growing?** Every turn re-sends the conversation. With
caching on, the re-sent prefix is billed at about a tenth of the input price. The budget guard
prices your usage the same way, so the growing count is not the growing cost.

**Can I use my own API key?** No. Bearer-token auth is denied by policy; everything is tied to your
SSO identity so the audit trail and your budget are accurate.

**Cross-region inference checkbox?** Only for tiers your admin marked `cross_region: true`
(Fable 5.1 in GovCloud). In-region tiers should leave it off.
