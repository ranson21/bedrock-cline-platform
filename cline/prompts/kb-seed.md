# Task: build the team knowledge base from this repository

You are seeding a Bedrock Knowledge Base (vector search over OpenSearch) that every engineer on
the team will query from Cline through the `search_knowledge_base` tool. The index is empty.
Your job is to read this repository and any docs it references, and write a set of
self-contained Markdown documents into `./knowledge/` that answer the questions engineers
actually ask: what does this system do, how is it laid out, how do I build, test, deploy and
debug it, what conventions must I follow, what are the known sharp edges.

## Rules for the output

- Write to `./knowledge/<repo-name>/`. Do not modify any other file.
- Each document is Markdown, 300 to 1,500 words, one topic, with a `#` title and `##` sections.
  Retrieval returns chunks of about 500 tokens, so every section must make sense on its own:
  restate the subject in each section's first sentence and never say "as above".
- Start each document with a short YAML front-matter block:
  ```yaml
  ---
  repo: <repo-name>
  kind: overview | architecture | module | howto | convention | runbook | glossary | faq
  audience: developer | end-user | all
  paths: [relative/paths/this/doc/describes]
  updated: <YYYY-MM-DD>
  ---
  ```
- Next to each document write `<name>.md.metadata.json` containing
  `{"metadataAttributes": {"repo": "<repo-name>", "kind": "<kind>", "audience": "<audience>"}}`
  so results can be filtered by repo, kind and audience.
- `audience` gates who can retrieve the document. `developer` for anything that cites code,
  internals, infrastructure or credentials handling; `end-user` for how-to and FAQ content
  written for people who use the product; `all` only when the text is safe and useful for both.
  When in doubt, `developer`.
- Cite file paths (`src/api/router.ts:42`) instead of pasting large code blocks. Short snippets
  (under 15 lines) are fine when they are the canonical example.
- Do not include secrets, credentials, account ids, internal hostnames, or personal data. If a
  file contains them, describe where the value comes from, not the value.
- Prefer facts from the code over facts from stale docs; when they disagree, say so and cite both.

## Documents to produce (skip any that do not apply, add others if the repo warrants)

1. `00-overview.md` — purpose, users, main entry points, how to run it locally in five commands.
2. `10-architecture.md` — components, data flow, external dependencies, one ASCII diagram.
3. `20-<module>.md` — one per top-level module or service: responsibility, public interfaces,
   key files, how to test it, common changes and where they go.
4. `30-build-test-deploy.md` — exact commands, CI stages, environments, how to roll back.
5. `40-conventions.md` — code style, naming, error handling, logging, commit and PR rules,
   anything enforced by lint or review.
6. `50-runbook-<topic>.md` — one per operational scenario you can infer (incident, migration,
   rotating a dependency, common failure and its fix).
7. `60-glossary.md` — domain terms, acronyms, service names, with one-line definitions.
8. `70-faq.md` — 10 to 30 questions a new engineer asks in week one, each with a direct answer
   and a file path.
8b. `80-user-guide-<topic>.md` — for products with end users: task-oriented guides written for
   them, `audience: end-user`, no file paths, no internals.
9. `90-gaps.md` — things you could not determine from the repo, with the question that a human
   must answer. This is for the platform admin, not for retrieval.

## How to work

- Start by listing the tree, `README*`, `docs/`, `CONTRIBUTING*`, `Makefile`, CI config, package
  manifests, and infrastructure directories. Then read entry points and the largest modules.
- Use search (grep/glob) to confirm claims before writing them. Read ranges, not whole files,
  when a file is over 300 lines.
- Write documents incrementally: finish one, move to the next. Do not wait until the end.
- When done, print the list of files written and the `90-gaps.md` questions, then stop.
  Do not upload anything; the platform admin runs the sync.
