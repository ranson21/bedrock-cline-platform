#!/usr/bin/env python3
"""Sync a local docs directory (or git checkout) to the knowledge-base bucket and trigger ingestion.

Usage: python tools/sync-docs/sync_docs.py --live terragrunt/live/dev --src ./docs [--prefix team-docs/] [--wait]
Only text-like files are uploaded (md, txt, rst, adoc, pdf, html, json, yaml, py, ts, go, java, tf ...).
"""

from __future__ import annotations

import argparse
import hashlib
import mimetypes
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from common.live import read_account_hcl, session, tg_output  # noqa: E402

EXT = {".md", ".txt", ".rst", ".adoc", ".pdf", ".html", ".json", ".yaml", ".yml", ".py", ".ts", ".tsx", ".js", ".go", ".java", ".kt", ".tf", ".hcl", ".sh", ".sql", ".csv", ".docx"}
SKIP_DIRS = {".git", "node_modules", ".terraform", "dist", "build", "__pycache__", ".venv"}


def files(src: Path):
    for p in src.rglob("*"):
        if p.is_file() and p.suffix.lower() in EXT and not any(part in SKIP_DIRS for part in p.parts):
            yield p


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--live", required=True)
    ap.add_argument("--src", required=True)
    ap.add_argument("--prefix", default="")
    ap.add_argument("--profile", default=None)
    ap.add_argument("--wait", action="store_true")
    a = ap.parse_args()
    live, src = Path(a.live), Path(a.src)
    s = session(read_account_hcl(live), a.profile)
    bucket = tg_output(live, "knowledge-base", "docs_bucket_name")
    kb_id = tg_output(live, "knowledge-base", "knowledge_base_id")
    ds_id = tg_output(live, "knowledge-base", "data_source_id")
    s3 = s.client("s3")

    existing = {}
    for page in s3.get_paginator("list_objects_v2").paginate(Bucket=bucket, Prefix=a.prefix):
        for o in page.get("Contents", []):
            existing[o["Key"]] = o["ETag"].strip('"')
    uploaded = 0
    seen = set()
    for f in files(src):
        key = a.prefix + f.relative_to(src).as_posix()
        seen.add(key)
        md5 = hashlib.md5(f.read_bytes()).hexdigest()  # noqa: S324 (ETag comparison only)
        if existing.get(key) == md5:
            continue
        s3.upload_file(str(f), bucket, key, ExtraArgs={"ContentType": mimetypes.guess_type(f.name)[0] or "text/plain"})
        uploaded += 1
    removed = 0
    for key in existing:
        if key.startswith(a.prefix) and key not in seen:
            s3.delete_object(Bucket=bucket, Key=key)
            removed += 1
    print(f"uploaded {uploaded}, removed {removed}, unchanged {len(seen) - uploaded}")

    agent = s.client("bedrock-agent")
    try:
        job = agent.start_ingestion_job(knowledgeBaseId=kb_id, dataSourceId=ds_id, description="sync-docs")["ingestionJob"]
    except agent.exceptions.ConflictException:
        print("ingestion already running")
        return 0
    print(f"ingestion job {job['ingestionJobId']} started")
    if a.wait:
        while job["status"] in ("STARTING", "IN_PROGRESS"):
            time.sleep(10)
            job = agent.get_ingestion_job(knowledgeBaseId=kb_id, dataSourceId=ds_id, ingestionJobId=job["ingestionJobId"])["ingestionJob"]
        print(f"status {job['status']}: {job.get('statistics')}")
    return 0


if __name__ == "__main__":
    try:
        subprocess.run(["true"], check=True)
    finally:
        raise SystemExit(main())
