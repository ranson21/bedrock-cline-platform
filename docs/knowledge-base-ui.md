# Knowledge-base UI: a prompt deliverable

The platform gives engineers retrieval inside Cline. End users and non-engineers need a web
surface for the same knowledge base, gated by role so a product user never sees a developer
runbook. Rather than ship another app to host, this guide has the agent **build the UI into
your existing application**, in that application's own stack, auth, and deploy pipeline. It
inherits your IdP and your infrastructure; the only new code is the feature itself.

There is no standard end-user UI for this in AWS. OpenSearch Dashboards is an operator tool,
the Bedrock console chat is console-only, and Amazon Q Business is not something to count on in
GovCloud. So the feature is yours to build, and the agent can build it in an afternoon.

## What the platform admin provides first

Collect these before handing the prompt to whoever owns the target application.

| Input | Where it comes from |
|---|---|
| `KB_ID` | `terragrunt output -raw knowledge_base_id` in the `knowledge-base` unit |
| `AWS_REGION` | `account.hcl` |
| Generation model id | e.g. `anthropic.claude-sonnet-5` in-region, or the `us-gov.` geo profile id for cross-region tiers. Sonnet 5 is the right default for Q&A. |
| Group-to-audience mapping | which IdP groups may see `developer`, `end-user`, `all` content (see below) |
| IAM policy for the app's runtime role | the JSON below, attached by whoever owns that role |

The application's existing runtime identity (ECS task role, Lambda role, EC2 instance profile,
EKS service account) needs this policy. The knowledge base is queried through Bedrock, so no
OpenSearch permissions are required.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "QueryKnowledgeBase",
      "Effect": "Allow",
      "Action": ["bedrock:Retrieve", "bedrock:RetrieveAndGenerate"],
      "Resource": "arn:<partition>:bedrock:<region>:<account-id>:knowledge-base/<KB_ID>"
    },
    {
      "Sid": "GenerateAnswers",
      "Effect": "Allow",
      "Action": ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"],
      "Resource": [
        "arn:<partition>:bedrock:<region>::foundation-model/<generation-model-id>",
        "arn:<partition>:bedrock:<region>:<account-id>:inference-profile/*"
      ]
    }
  ]
}
```

The app's calls are logged like every other invocation. They show up in `make usage` under the
role's session name rather than an engineer, which is the correct attribution.

## Role gating model

Every document in the index carries an `audience` metadata attribute set by the seeding prompt
(`developer`, `end-user`, or `all`). The UI never decides what a user may see; the API does, by
translating the caller's IdP groups into a metadata filter on every retrieval:

| Caller's groups include | Allowed audiences |
|---|---|
| `bedrock-engineers` or `bedrock-admins` (or your engineering group) | `developer`, `end-user`, `all` |
| any other authenticated user | `end-user`, `all` |
| unauthenticated | no access |

Because the filter is applied inside the retrieval call, an over-broad question cannot leak a
developer document into an end-user answer. Adjust the group names to match your IdP.

## The prompt

Open the target application's repository in VS Code with Cline configured per
`docs/cline-setup.md`, start in Plan mode, and paste everything below the line. Fill the
placeholders in the first block first.

---

```
# Task: add a knowledge-base search and Q&A feature to this application

## Inputs (filled by the platform admin)
KB_ID: <knowledge base id>
AWS_REGION: <region>
GENERATION_MODEL_ID: <e.g. anthropic.claude-sonnet-5>
DEVELOPER_GROUPS: [<idp group names that may see developer content>]
FEATURE_PATH: /help/ask        # route where the UI lives; change to fit the app

## Goal
Add a feature to THIS application, in its existing stack and conventions, that lets a signed-in
user ask questions of the team knowledge base (an Amazon Bedrock Knowledge Base) and get an
answer with citations. Access is role-gated: developers see everything, everyone else sees only
documents tagged for end users. Reuse the app's existing authentication, session handling,
authorization helpers, HTTP client patterns, UI components, tests, and deployment. Do not add a
new service, a new auth mechanism, or a new hosting target.

## Before writing code
1. Learn the shape of this app. Read the README, the top-level layout, how routes/pages are
   defined, how the backend calls AWS today (SDK version, credential handling, region config),
   how the current user and their groups are obtained on the server, how feature flags or
   settings are managed, how components are styled, and how tests are written and run.
2. Find the exact server-side function that yields the caller's identity and group list. If
   the app has none, stop and report; do not invent one.
3. Propose the file list you will add or change, and the API contract, and wait for approval
   before switching to Act mode.

## What to build
### Backend
- One endpoint, e.g. `POST FEATURE_PATH/api/ask` (match the app's routing style), body
  `{ "question": string, "conversationId"?: string }`, response
  `{ "answer": string, "citations": [{ "title", "source", "excerpt" }], "conversationId" }`.
- Authorization: require an authenticated session. Compute `allowedAudiences`:
  `["developer","end-user","all"]` if any of the user's groups is in DEVELOPER_GROUPS, else
  `["end-user","all"]`. Never trust a client-supplied audience.
- Call Bedrock `RetrieveAndGenerate` (bedrock-agent-runtime) with:
  - `knowledgeBaseId = KB_ID`
  - `modelArn` for GENERATION_MODEL_ID in AWS_REGION (foundation-model ARN, or inference-profile
    ARN if the id has a geo prefix)
  - `retrievalConfiguration.vectorSearchConfiguration.numberOfResults = 6`
  - `retrievalConfiguration.vectorSearchConfiguration.filter =
      { "in": { "key": "audience", "value": allowedAudiences } }`
  - pass `sessionId` through as `conversationId` so follow-up questions keep context.
- Map the response citations to `{title, source, excerpt}` where `source` is the S3 URI's
  path after the bucket, not the full URI, and `title` is the document's first heading if it is
  present in the excerpt, else the filename.
- Use the AWS SDK already in the project and its existing credential chain. Region from the
  app's existing config. No access keys in code or config.
- Errors: 401 if unauthenticated, 429 passthrough with a friendly message if Bedrock throttles,
  502 with a request id on other Bedrock errors. Log the request id, the user id, the audience
  set, and token usage if the SDK returns it. Never log the question text at info level.
- Rate limit per user using whatever the app already uses (or a simple in-memory limiter if
  nothing exists): 20 questions per minute.

### Frontend
- A page or panel at FEATURE_PATH built from the app's existing components: a question box, a
  streaming-or-not answer area (match what the app supports), a citations list with each
  source rendered as a chip or link, a "new conversation" action, and an empty state that
  explains what the knowledge base covers.
- Show the user's effective audience ("Showing developer and user documentation" vs "Showing
  user documentation") so gating is visible, not mysterious.
- Keep answers in the conversation until "new conversation"; do not persist to storage unless
  the app already persists user activity, in which case follow that pattern.
- Accessibility and i18n as the app does them.

### Tests
- Unit tests for the audience mapping (developer group → three audiences; other → two;
  unauthenticated → 401).
- A test that the Bedrock call includes the audience filter for both cases (mock the SDK the
  way the app mocks other AWS calls).
- A component test for the citations rendering.
- Run the app's full test and lint commands before finishing.

### Docs and rollout
- Add a short section to the app's README: what the feature does, the IAM policy the runtime
  role needs (copy from the platform's docs/knowledge-base-ui.md), and the config keys.
- Put the feature behind the app's feature-flag or settings mechanism if it has one, default
  off in production.
- Print a summary: files changed, config keys added, the exact IAM policy to attach, and any
  assumptions you made about group names or auth.

## Rules
- Match existing code style exactly; run the formatter the repo uses.
- Small, reviewable commits or a single clean diff, as the repo prefers.
- Do not modify unrelated files, upgrade dependencies, or restructure directories.
- Do not add secrets, account ids, or hostnames to source; read them from the app's config.
```

---

## Acceptance checklist

- [ ] A developer-group user asks "how do we deploy?" and gets an answer citing a
      `developer` document.
- [ ] A non-developer asks the same question and gets either an end-user document or "I could
      not find that in the documentation", never a developer citation.
- [ ] The runtime role has only the policy above; no OpenSearch or S3 permissions.
- [ ] The feature's invocations appear in `make usage` under the app role.
- [ ] Throttling and Bedrock errors render as friendly messages with a request id.

## Variations

- **Search instead of chat:** replace `RetrieveAndGenerate` with `Retrieve` and render the
  passages; no generation model, no model spend, same filter.
- **Per-repo scoping:** add `repo` to the filter as an `andAll` with the audience clause.
- **Guardrail:** pass `generationConfiguration.guardrailConfiguration` with the platform's
  guardrail id (`terragrunt output guardrail_id` in `bedrock-core`) to apply PII masking to
  generated answers.
