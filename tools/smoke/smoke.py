#!/usr/bin/env python3
"""Post-deploy smoke test.

1. Invokes every engineer inference profile once (as the deployer) and checks the response.
2. Sends a >2k-token cached system prompt twice and asserts cacheReadInputTokens > 0
   on the second call, proving prompt caching works for this model in this region.
3. Runs a Retrieve against the knowledge base.

Usage: python tools/smoke/smoke.py --live terragrunt/live/dev [--profile admin]
"""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from common.live import read_account_hcl, session, tg_output  # noqa: E402

FILLER = ("You are a careful senior engineer. Follow the agency coding standards below.\n" + "Standard: prefer explicit error handling; never swallow exceptions; write tests first.\n" * 120)


def converse(rt, model_id: str, prompt: str, cache: bool):
    system = [{"text": FILLER}]
    if cache:
        system.append({"cachePoint": {"type": "default"}})
    return rt.converse(
        modelId=model_id,
        system=system,
        messages=[{"role": "user", "content": [{"text": prompt}]}],
        inferenceConfig={"maxTokens": 64},
    )


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--live", required=True)
    ap.add_argument("--profile", default=None)
    args = ap.parse_args()
    live = Path(args.live)
    acct = read_account_hcl(live)
    s = session(acct, args.profile)
    rt = s.client("bedrock-runtime")
    failures = 0

    profiles = tg_output(live, "bedrock-core", "engineer_profiles")
    print(f"== Invoking {sum(len(v) for v in profiles.values())} profiles")
    for user, tiers in sorted(profiles.items()):
        for tier, arn in tiers.items():
            try:
                r = converse(rt, arn, "Reply with the single word OK.", cache=False)
                text = r["output"]["message"]["content"][0]["text"].strip()
                print(f"  ✔ {user}/{tier}: {text[:20]!r}  in={r['usage']['inputTokens']} out={r['usage']['outputTokens']}")
            except Exception as e:  # noqa: BLE001
                failures += 1
                print(f"  ✘ {user}/{tier}: {e}")

    print("== Prompt caching")
    any_arn = next(iter(next(iter(profiles.values())).values()))
    converse(rt, any_arn, "Say OK.", cache=True)
    time.sleep(2)
    r = converse(rt, any_arn, "Say OK again.", cache=True)
    cr = r["usage"].get("cacheReadInputTokens", 0)
    cw = r["usage"].get("cacheWriteInputTokens", 0)
    if cr > 0:
        print(f"  ✔ cache hit: cacheRead={cr} cacheWrite={cw} input={r['usage']['inputTokens']}")
    else:
        failures += 1
        print(f"  ✘ no cache read on second call (cacheWrite={cw}). Check model supports caching in this region.")

    print("== Knowledge base")
    try:
        kb_id = tg_output(live, "knowledge-base", "knowledge_base_id")
        agent_rt = s.client("bedrock-agent-runtime")
        out = agent_rt.retrieve(knowledgeBaseId=kb_id, retrievalQuery={"text": "coding standards"}, retrievalConfiguration={"vectorSearchConfiguration": {"numberOfResults": 3}})
        n = len(out.get("retrievalResults", []))
        print(f"  ✔ retrieve returned {n} results" + (" (upload docs with make sync-docs)" if n == 0 else ""))
    except Exception as e:  # noqa: BLE001
        failures += 1
        print(f"  ✘ retrieve failed: {e}")

    print("SMOKE OK" if failures == 0 else f"SMOKE FAILED ({failures})")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
