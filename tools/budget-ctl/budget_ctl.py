#!/usr/bin/env python3
"""Administer per-engineer budgets at runtime, without a Terraform apply.

  budget_ctl.py --live L status jane.doe
  budget_ctl.py --live L grant jane.doe --usd 120 [--tokens 12000000] [--month 2026-09] [--note "..."]
  budget_ctl.py --live L unlock jane.doe          # clear exhausted / cache_disabled now
  budget_ctl.py --live L lock jane.doe            # suspend access immediately
  budget_ctl.py --live L clear-override jane.doe
  budget_ctl.py --live L reset-all                # what the monthly cron does
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from decimal import Decimal
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from common.live import read_account_hcl, session, tg_output  # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--live", required=True)
    ap.add_argument("--profile", default=None)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("status")
    p.add_argument("user")
    p = sub.add_parser("grant")
    p.add_argument("user")
    p.add_argument("--usd", type=float)
    p.add_argument("--tokens", type=int)
    p.add_argument("--month", default=datetime.now(timezone.utc).strftime("%Y-%m"))
    p.add_argument("--note", default="")
    p.add_argument("--no-enforce", action="store_true")
    p = sub.add_parser("unlock")
    p.add_argument("user")
    p = sub.add_parser("lock")
    p.add_argument("user")
    p = sub.add_parser("clear-override")
    p.add_argument("user")
    sub.add_parser("reset-all")
    a = ap.parse_args()

    live = Path(a.live)
    s = session(read_account_hcl(live), a.profile)
    table = s.resource("dynamodb").Table(tg_output(live, "budget-guard", "table_name"))
    admin_fn = tg_output(live, "budget-guard", "admin_function_name")
    cfg = json.loads(s.client("ssm").get_parameter(Name=tg_output(live, "budget-guard", "config_parameter_name"))["Parameter"]["Value"])
    lam = s.client("lambda")
    bedrock = s.client("bedrock")
    month = datetime.now(timezone.utc).strftime("%Y-%m")

    def profiles(user):
        return [arn for arn, m in cfg["profiles"].items() if m["owner"] == user]

    if a.cmd == "status":
        item = table.get_item(Key={"PK": f"USER#{a.user}", "SK": f"MONTH#{month}"}).get("Item", {})
        ov = table.get_item(Key={"PK": f"USER#{a.user}", "SK": "OVERRIDE"}).get("Item")
        print(json.dumps({"month": {k: (float(v) if isinstance(v, Decimal) else (sorted(v) if isinstance(v, set) else v)) for k, v in item.items()},
                          "override": {k: (float(v) if isinstance(v, Decimal) else v) for k, v in (ov or {}).items()} or None,
                          "profiles": {arn: {t["key"]: t["value"] for t in bedrock.list_tags_for_resource(resourceARN=arn)["tags"]}.get("budget_state") for arn in profiles(a.user)}}, indent=2))
    elif a.cmd == "grant":
        item = {"PK": f"USER#{a.user}", "SK": "OVERRIDE", "expires_month": a.month, "note": a.note, "set_at": datetime.now(timezone.utc).isoformat()}
        if a.usd is not None:
            item["monthly_usd_budget"] = Decimal(str(a.usd))
        if a.tokens is not None:
            item["monthly_token_budget"] = a.tokens
        if a.no_enforce:
            item["enforce"] = False
        table.put_item(Item=item)
        lam.invoke(FunctionName=admin_fn, Payload=json.dumps({"action": "unlock", "user": a.user}).encode())
        print(f"override set for {a.user} through {a.month}; profiles unlocked")
    elif a.cmd == "unlock":
        r = lam.invoke(FunctionName=admin_fn, Payload=json.dumps({"action": "unlock", "user": a.user}).encode())
        print(r["Payload"].read().decode())
    elif a.cmd == "lock":
        for arn in profiles(a.user):
            bedrock.tag_resource(resourceARN=arn, tags=[{"key": "budget_state", "value": "exhausted"}])
        table.update_item(Key={"PK": f"USER#{a.user}", "SK": f"MONTH#{month}"}, UpdateExpression="SET #s = :v",
                          ExpressionAttributeNames={"#s": "state"}, ExpressionAttributeValues={":v": "exhausted"})
        print(f"locked {len(profiles(a.user))} profiles for {a.user}")
    elif a.cmd == "clear-override":
        table.delete_item(Key={"PK": f"USER#{a.user}", "SK": "OVERRIDE"})
        print("override cleared")
    elif a.cmd == "reset-all":
        r = lam.invoke(FunctionName=admin_fn, Payload=json.dumps({"action": "reset"}).encode())
        print(r["Payload"].read().decode())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
