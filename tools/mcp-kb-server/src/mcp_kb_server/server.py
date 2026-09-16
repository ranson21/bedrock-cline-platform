"""MCP server that lets Cline search the team knowledge base (Bedrock Knowledge Bases).

Runs locally over stdio with the engineer's own AWS credentials, so access is governed by
the same Identity Center permission set as model invocation (bedrock:Retrieve).

Environment:
  KB_ID        knowledge base id (required)
  AWS_PROFILE  Identity Center profile name (optional; standard AWS credential chain otherwise)
  AWS_REGION   region of the knowledge base
  KB_TOP_K     default number of results (default 6)
"""

from __future__ import annotations

import os

import boto3
from mcp.server.fastmcp import FastMCP

mcp = FastMCP("team-knowledge-base")
_client = None


def client():
    global _client
    if _client is None:
        _client = boto3.session.Session(
            profile_name=os.environ.get("AWS_PROFILE") or None,
            region_name=os.environ.get("AWS_REGION"),
        ).client("bedrock-agent-runtime")
    return _client


@mcp.tool()
def search_knowledge_base(query: str, top_k: int | None = None) -> str:
    """Search the team's internal docs, ADRs, runbooks and code guides.

    Use this before asking the user about team conventions, service names, deployment
    steps or architecture decisions. Returns the most relevant passages with their sources.
    """
    kb_id = os.environ["KB_ID"]
    k = top_k or int(os.environ.get("KB_TOP_K", "6"))
    resp = client().retrieve(
        knowledgeBaseId=kb_id,
        retrievalQuery={"text": query},
        retrievalConfiguration={"vectorSearchConfiguration": {"numberOfResults": k}},
    )
    results = resp.get("retrievalResults", [])
    if not results:
        return "No results."
    out = []
    for i, r in enumerate(results, 1):
        loc = r.get("location", {})
        src = loc.get("s3Location", {}).get("uri") or loc.get("type", "")
        score = r.get("score")
        text = r.get("content", {}).get("text", "").strip()
        out.append(f"[{i}] source: {src}" + (f" (score {score:.3f})" if score is not None else "") + f"\n{text}\n")
    return "\n".join(out)


@mcp.tool()
def knowledge_base_info() -> str:
    """Describe what the knowledge base contains and how to add to it."""
    return (
        f"Knowledge base id: {os.environ.get('KB_ID', 'unset')}. Content is synced from the docs bucket with "
        "`make sync-docs`; ask a platform admin to add a directory. Results are passages, not whole files; "
        "cite the source URI when you use them."
    )


def main() -> None:
    mcp.run()


if __name__ == "__main__":
    main()
