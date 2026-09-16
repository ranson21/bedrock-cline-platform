"""Budget Guard admin Lambda: monthly reset and daily digest.

event = {"action": "reset"}   -> set budget_state=ok on every engineer profile, post last month's summary
event = {"action": "digest"}  -> post this month's per-engineer spend summary
event = {"action": "unlock", "user": "jane.doe"} -> re-enable one engineer (used by budget-ctl)
"""

from __future__ import annotations

import json
import logging
import os
from datetime import datetime, timedelta, timezone
from decimal import Decimal

import boto3
from boto3.dynamodb.conditions import Key

log = logging.getLogger()
log.setLevel(logging.INFO)

TABLE_NAME = os.environ["TABLE_NAME"]
CONFIG_PARAM = os.environ["CONFIG_PARAM"]
ALERT_TOPIC_ARN = os.environ.get("ALERT_TOPIC_ARN", "")
NAME_PREFIX = os.environ.get("NAME_PREFIX", "bcp")

ddb = boto3.resource("dynamodb")
ssm = boto3.client("ssm")
sns = boto3.client("sns")
bedrock = boto3.client("bedrock")


def config() -> dict:
    return json.loads(ssm.get_parameter(Name=CONFIG_PARAM)["Parameter"]["Value"])


def month(offset: int = 0) -> str:
    d = datetime.now(timezone.utc).replace(day=1)
    for _ in range(abs(offset)):
        d = (d - timedelta(days=1)).replace(day=1) if offset < 0 else (d + timedelta(days=32)).replace(day=1)
    return d.strftime("%Y-%m")


def month_items(m: str) -> list[dict]:
    t = ddb.Table(TABLE_NAME)
    items, kwargs = [], {"IndexName": "SK-index", "KeyConditionExpression": Key("SK").eq(f"MONTH#{m}")}
    while True:
        r = t.query(**kwargs)
        items.extend(r.get("Items", []))
        if "LastEvaluatedKey" not in r:
            return items
        kwargs["ExclusiveStartKey"] = r["LastEvaluatedKey"]


def set_state(user: str, state: str, cfg: dict) -> int:
    n = 0
    for arn, meta in cfg.get("profiles", {}).items():
        if meta.get("owner") == user:
            bedrock.tag_resource(resourceARN=arn, tags=[{"key": "budget_state", "value": state}])
            n += 1
    return n


def summary(m: str, cfg: dict) -> str:
    items = sorted(month_items(m), key=lambda i: -int(i.get("usd_micros", 0)))
    lines = [f"{'engineer':<28}{'team':<12}{'req':>6}{'tokens':>14}{'cache%':>8}{'usd':>9}{'state':>15}"]
    total_usd = Decimal(0)
    for i in items:
        user = i["PK"].split("#", 1)[1]
        usd = Decimal(i.get("usd_micros", 0)) / Decimal(1_000_000)
        total_usd += usd
        inp = int(i.get("input_tokens", 0))
        cr = int(i.get("cache_read_tokens", 0))
        rate = (cr / (inp + cr)) if (inp + cr) else 0
        lines.append(
            f"{user:<28}{str(i.get('team', ''))[:11]:<12}{int(i.get('requests', 0)):>6}"
            f"{int(i.get('total_tokens', 0)):>14,}{rate:>8.0%}{float(usd):>9.2f}{str(i.get('state', 'ok')):>15}"
        )
    lines.append(f"\nTotal: ${float(total_usd):.2f} across {len(items)} engineers for {m}")
    return "\n".join(lines)


def handler(event, context):
    action = (event or {}).get("action", "digest")
    cfg = config()
    if action == "reset":
        users = {meta.get("owner") for meta in cfg.get("profiles", {}).values()}
        for u in users:
            set_state(u, "ok", cfg)
        body = "All engineer profiles reset to budget_state=ok.\n\nLast month:\n" + summary(month(-1), cfg)
        _publish(f"[{NAME_PREFIX}] Monthly budget reset complete", body)
        return {"reset": len(users)}
    if action == "unlock":
        n = set_state(event["user"], "ok", cfg)
        ddb.Table(TABLE_NAME).update_item(
            Key={"PK": f"USER#{event['user']}", "SK": f"MONTH#{month()}"},
            UpdateExpression="SET #s = :ok",
            ExpressionAttributeNames={"#s": "state"},
            ExpressionAttributeValues={":ok": "ok"},
        )
        return {"unlocked_profiles": n}
    body = summary(month(), cfg)
    _publish(f"[{NAME_PREFIX}] Daily AI spend digest {month()}", body)
    return {"digest": True}


def _publish(subject: str, body: str) -> None:
    if ALERT_TOPIC_ARN:
        sns.publish(TopicArn=ALERT_TOPIC_ARN, Subject=subject[:100], Message=body)
    log.info(body)
