"""Read a terragrunt/live/<env>/ directory so tools know which account and prefix to talk to."""

from __future__ import annotations

import json
import re
import subprocess
from pathlib import Path

import boto3


def read_account_hcl(live_dir: Path) -> dict:
    text = (live_dir / "account.hcl").read_text()
    out = {}
    for key in ("account_id", "partition", "region", "environment", "name_prefix", "deploy_role_arn"):
        m = re.search(rf'^\s*{key}\s*=\s*"([^"]*)"', text, re.M)
        if m:
            out[key] = m.group(1)
    return out


def tg_output(live_dir: Path, unit: str, name: str):
    """Read a Terragrunt output without needing the AWS console."""
    r = subprocess.run(
        ["terragrunt", "output", "-json", name],
        cwd=live_dir / unit,
        capture_output=True,
        text=True,
        check=True,
    )
    return json.loads(r.stdout)


def session(acct: dict, profile: str | None = None) -> boto3.session.Session:
    s = boto3.session.Session(profile_name=profile, region_name=acct["region"])
    if acct.get("deploy_role_arn"):
        creds = s.client("sts").assume_role(RoleArn=acct["deploy_role_arn"], RoleSessionName="bcp-tools")["Credentials"]
        s = boto3.session.Session(
            aws_access_key_id=creds["AccessKeyId"],
            aws_secret_access_key=creds["SecretAccessKey"],
            aws_session_token=creds["SessionToken"],
            region_name=acct["region"],
        )
    ident = s.client("sts").get_caller_identity()
    if ident["Account"] != acct["account_id"]:
        raise SystemExit(f"authenticated to account {ident['Account']} but {live_dir_name(acct)} expects {acct['account_id']}")
    return s


def live_dir_name(acct: dict) -> str:
    return f"live/{acct.get('environment', '?')}"
