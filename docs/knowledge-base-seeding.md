# Seeding the knowledge base with the agent

After the first deployment the knowledge base exists but its OpenSearch index is empty.
Nothing populates it automatically. This guide fills it by pointing Cline, running on the
platform you just deployed, at your codebases and having it write the documents that get
indexed. The loop is: **agent writes curated docs → admin syncs them to S3 → ingestion Lambda
builds the index → everyone's Cline can search it.**

Indexing raw source files is deliberately not the approach. Retrieval works on 500-token chunks,
and a chunk of code without its context is rarely a useful answer. Curated documents that
explain the code, with file paths as citations, are what make `search_knowledge_base` worth
calling.

## Prerequisites

- `make apply` and `make smoke` have succeeded; the knowledge base id is in `make profiles`
  output or `terragrunt output -raw knowledge_base_id` in the `knowledge-base` unit.
- Someone with the **admin** permission set (`<prefix>-BedrockAdmin`) to run the sync. The
  admin set can write the docs bucket; the engineer set cannot.
- Cline configured per `docs/cline-setup.md`. The seeding session is a normal Cline task and is
  metered against the budget of whoever runs it, so use a Sonnet 5 profile and expect roughly
  one to three million tokens per mid-sized repository with caching on.

## 1. Run the seeding task in each repository

1. Open the repository in VS Code and copy `cline/.clinerules` into its root if it is not there.
2. Open Cline in **Plan mode**, paste the contents of `cline/prompts/kb-seed.md`, and let it
   propose the document list. Adjust the list if it missed a module or is about to document
   generated code.
3. Switch to **Act mode**. Auto-approve read and write for `./knowledge/**` only. The prompt
   forbids edits elsewhere, but keep other writes on manual approval.
4. When it finishes, review `knowledge/<repo>/90-gaps.md`. Answer what you can in the relevant
   documents and delete the gaps file, or leave it: it is excluded from the index by the sync
   step's prefix filter below only if you delete it, so decide deliberately.
5. Skim two or three documents for secrets, hostnames, or account ids. The prompt forbids them,
   and the guardrail masks common patterns at query time, but the index is shared by the whole
   team.

Repeat for every repository the team works in. Platform docs (this repo's `docs/`) are a good
first target because they answer "how do I use Cline here" questions.

## 2. Sync and index

From this repository, with the admin profile active:

```bash
make sync-docs ENV=dev ARGS="--src /path/to/repo/knowledge --prefix repos/ --wait"
```

The tool uploads changed files only, deletes files that disappeared under the prefix, starts an
ingestion job, and with `--wait` prints the job statistics when it completes. A few hundred
documents index in a couple of minutes. The EventBridge rule would also have started ingestion
on upload; the tool just starts it immediately and waits.

Then verify from any engineer's Cline: *"Ask the knowledge base how deploys work for
`<repo>`."* You should see passages with `s3://.../repos/<repo>/30-build-test-deploy.md` as
the source. `make smoke` also runs a retrieve.

## 3. Keep it current

Options, from least to most automated:

- **Manual.** Re-run the seeding task after significant changes; ask it to "update the existing
  documents in `./knowledge/` to reflect the current code, and list what changed." Sync again.
- **Scheduled.** The `knowledge-base` unit has `ingestion_schedule` (default daily) which
  re-indexes whatever is in the bucket, so a nightly job that runs `sync_docs.py` from a
  checkout keeps the index fresh without anyone thinking about it.
- **On merge.** Add a CI step in each repository that runs `tools/sync-docs/sync_docs.py` with a
  role that can write the docs bucket. Keep `knowledge/` in the repository and require the
  seeding task to run on pull requests that change documented modules.

Commit `knowledge/` to each repository. It is useful documentation on its own, it is reviewable,
and it means a fresh index can be rebuilt from git at any time.

## Metadata and filtering

Each document's sidecar `<name>.md.metadata.json` becomes filterable attributes in Bedrock.
`search_knowledge_base` does not expose filters yet; if you want per-repo scoping, add a
`repo` argument to `tools/mcp-kb-server` that passes
`retrievalConfiguration.vectorSearchConfiguration.filter = {"equals": {"key": "repo", "value": ...}}`.

## Costs

The index size drives OpenSearch storage, which is cents per GB. The seeding session itself is
the notable cost: a 50k-line repository typically costs a few dollars on Sonnet 5 with caching.
Ingestion embeddings with Titan v2 are fractions of a cent per document.
