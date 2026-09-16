#!/usr/bin/env python3
"""Per-engineer usage report from the Budget Guard table.

Usage: python tools/usage-report/usage_report.py --live terragrunt/live/dev [--month 2026-09] [--json]
"""

from __future__ import annotations

import argparse
import calendar
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

from boto3.dynamodb.conditions import Key

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from common.live import read_account_hcl, session, tg_output  # noqa: E402


def load(live: Path, s, month: str):
    table_name = tg_output(live, "budget-guard", "table_name")
    param = tg_output(live, "budget-guard", "config_parameter_name")
    cfg = json.loads(s.client("ssm").get_parameter(Name=param)["Parameter"]["Value"])
    t = s.resource("dynamodb").Table(table_name)
    items, kwargs = [], {"IndexName": "SK-index", "KeyConditionExpression": Key("SK").eq(f"MONTH#{month}")}
    while True:
        r = t.query(**kwargs)
        items.extend(r["Items"])
        if "LastEvaluatedKey" not in r:
            break
        kwargs["ExclusiveStartKey"] = r["LastEvaluatedKey"]
    overrides = {}
    for i in items:
        o = t.get_item(Key={"PK": i["PK"], "SK": "OVERRIDE"}).get("Item")
        if o:
            overrides[i["PK"]] = o
    return cfg, items, overrides


def budget_for(user, cfg, override):
    d = cfg["defaults"]
    e = cfg["engineers"].get(user, {})
    usd = float((override or {}).get("monthly_usd_budget") or e.get("monthly_usd_budget") or d["monthly_usd_budget"])
    tok = int((override or {}).get("monthly_token_budget") or e.get("monthly_token_budget") or d["monthly_token_budget"])
    return usd, tok


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--live", required=True)
    ap.add_argument("--month", default=datetime.now(timezone.utc).strftime("%Y-%m"))
    ap.add_argument("--profile", default=None)
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    live = Path(a.live)
    s = session(read_account_hcl(live), a.profile)
    cfg, items, overrides = load(live, s, a.month)

    now = datetime.now(timezone.utc)
    y, m = map(int, a.month.split("-"))
    days_in_month = calendar.monthrange(y, m)[1]
    day = now.day if now.strftime("%Y-%m") == a.month else days_in_month
    rows = []
    for i in items:
        user = i["PK"].split("#", 1)[1]
        usd = float(i.get("usd_micros", 0)) / 1e6
        inp, cr = int(i.get("input_tokens", 0)), int(i.get("cache_read_tokens", 0))
        usd_budget, tok_budget = budget_for(user, cfg, overrides.get(i["PK"]))
        rows.append({
            "user": user,
            "team": i.get("team", ""),
            "requests": int(i.get("requests", 0)),
            "input_tokens": inp,
            "cache_read_tokens": cr,
            "cache_write_tokens": int(i.get("cache_write_tokens", 0)),
            "output_tokens": int(i.get("output_tokens", 0)),
            "total_tokens": int(i.get("total_tokens", 0)),
            "cache_hit_rate": (cr / (inp + cr)) if (inp + cr) else 0.0,
            "usd": usd,
            "usd_budget": usd_budget,
            "pct": 100 * usd / usd_budget if usd_budget else 0,
            "projected_usd": usd / day * days_in_month,
            "token_budget": tok_budget,
            "state": i.get("state", "ok"),
        })
    rows.sort(key=lambda r: -r["usd"])
    if a.json:
        print(json.dumps({"month": a.month, "rows": rows}, indent=2))
        return 0
    print(f"Usage for {a.month} (day {day}/{days_in_month})\n")
    print(f"{'engineer':<26}{'team':<10}{'req':>6}{'tokens':>13}{'cache%':>8}{'out tok':>10}{'usd':>8}{'budget':>8}{'used':>6}{'proj':>8}  state")
    tot_usd = tot_tok = 0
    for r in rows:
        tot_usd += r["usd"]
        tot_tok += r["total_tokens"]
        print(f"{r['user']:<26}{r['team'][:9]:<10}{r['requests']:>6}{r['total_tokens']:>13,}{r['cache_hit_rate']:>8.0%}{r['output_tokens']:>10,}"
              f"{r['usd']:>8.2f}{r['usd_budget']:>8.0f}{r['pct']:>5.0f}%{r['projected_usd']:>8.2f}  {r['state']}")
    print(f"\n{'TOTAL':<26}{'':<10}{'':>6}{tot_tok:>13,}{'':>8}{'':>10}{tot_usd:>8.2f}   projected month-end ${tot_usd / day * days_in_month:.2f}")
    low = [r for r in rows if r["requests"] >= 20 and r["cache_hit_rate"] < cfg["defaults"].get("min_cache_hit_rate", 0.5)]
    if low:
        print("\nLow cache hit rate (caching probably off in Cline): " + ", ".join(f"{r['user']} {r['cache_hit_rate']:.0%}" for r in low))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
