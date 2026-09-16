"""Budget Guard usage meter Lambda.

Triggered by a CloudWatch Logs subscription on the Bedrock invocation log group.
For every ModelInvocationLog record it:
  1. de-duplicates on requestId,
  2. attributes tokens and USD to the engineer (via the application inference profile tags),
  3. updates the engineer's monthly counters in DynamoDB,
  4. raises 50/80/100% alerts and, at 100%, tags the engineer's profiles budget_state=exhausted,
  5. tracks prompt-cache hit rate and nudges/locks when caching is off,
  6. optionally indexes the record into an OpenSearch Serverless analytics collection.
"""

from __future__ import annotations

import json
import logging
import os
import time
import urllib.request
from decimal import Decimal

import boto3
import meter
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest
from botocore.exceptions import ClientError

log = logging.getLogger()
log.setLevel(logging.INFO)

TABLE_NAME = os.environ.get("TABLE_NAME", "")
CONFIG_PARAM = os.environ.get("CONFIG_PARAM", "")
ALERT_TOPIC_ARN = os.environ.get("ALERT_TOPIC_ARN", "")
ANALYTICS_ENDPOINT = os.environ.get("ANALYTICS_ENDPOINT", "")
DEDUPE_TTL_DAYS = int(os.environ.get("DEDUPE_TTL_DAYS", "3"))
NAME_PREFIX = os.environ.get("NAME_PREFIX", "bcp")

_session = boto3.session.Session()
_ddb = _session.resource("dynamodb")
_ssm = _session.client("ssm")
_sns = _session.client("sns")
_bedrock = _session.client("bedrock")
_config_cache: dict = {"at": 0.0, "value": None}


def load_config() -> dict:
    if _config_cache["value"] and time.time() - _config_cache["at"] < 300:
        return _config_cache["value"]
    value = json.loads(_ssm.get_parameter(Name=CONFIG_PARAM)["Parameter"]["Value"])
    _config_cache.update(at=time.time(), value=value)
    return value


def table():
    return _ddb.Table(TABLE_NAME)


def dedupe(request_id: str) -> bool:
    """True if this request has not been seen before."""
    if not request_id:
        return True
    try:
        table().put_item(
            Item={"PK": f"REQ#{request_id}", "SK": "REQ", "ttl": int(time.time()) + DEDUPE_TTL_DAYS * 86400},
            ConditionExpression="attribute_not_exists(PK)",
        )
        return True
    except ClientError as e:
        if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
            return False
        raise


def get_override(user: str) -> dict | None:
    resp = table().get_item(Key={"PK": f"USER#{user}", "SK": "OVERRIDE"})
    item = resp.get("Item")
    if not item:
        return None
    if item.get("expires_month") and item["expires_month"] < meter.month_key(None):
        return None
    return {k: (float(v) if isinstance(v, Decimal) else v) for k, v in item.items()}


def record_usage(u: meter.Usage, eligible: bool) -> dict:
    """Atomically add this request's usage to the user's monthly item and return the new totals."""
    resp = table().update_item(
        Key={"PK": f"USER#{u.owner}", "SK": f"MONTH#{u.month}"},
        UpdateExpression=(
            "ADD requests :one, input_tokens :i, output_tokens :o, cache_read_tokens :cr, "
            "cache_write_tokens :cw, total_tokens :t, usd_micros :m, "
            "win_requests :wr, win_input :wi, win_cache :wc "
            "SET team = :team, updated_at = :now"
        ),
        ExpressionAttributeValues={
            ":one": 1,
            ":i": u.input_tokens,
            ":o": u.output_tokens,
            ":cr": u.cache_read_tokens,
            ":cw": u.cache_write_tokens,
            ":t": u.total_tokens,
            ":m": int(round(u.usd * 1_000_000)),
            ":wr": 1 if eligible else 0,
            ":wi": u.input_tokens if eligible else 0,
            ":wc": u.cache_read_tokens if eligible else 0,
            ":team": u.team,
            ":now": u.timestamp,
        },
        ReturnValues="ALL_NEW",
    )
    item = resp["Attributes"]
    return {
        "usd": float(item.get("usd_micros", 0)) / 1_000_000,
        "total_tokens": int(item.get("total_tokens", 0)),
        "alerted": set(item.get("alerted", set())),
        "state": item.get("state", "ok"),
        "win_requests": int(item.get("win_requests", 0)),
        "win_input": int(item.get("win_input", 0)),
        "win_cache": int(item.get("win_cache", 0)),
        "cache_hit_rate": float(item.get("cache_hit_rate", 0)),
    }


def mark(u: meter.Usage, **attrs) -> None:
    """SET arbitrary attributes on the monthly item (state, cache stats, window reset)."""
    names = {f"#{k}": k for k in attrs}
    values = {f":{k}": v for k, v in attrs.items()}
    table().update_item(
        Key={"PK": f"USER#{u.owner}", "SK": f"MONTH#{u.month}"},
        UpdateExpression="SET " + ", ".join(f"#{k} = :{k}" for k in attrs),
        ExpressionAttributeNames=names,
        ExpressionAttributeValues=values,
    )


def add_alerted(u: meter.Usage, labels: list[str]) -> None:
    table().update_item(
        Key={"PK": f"USER#{u.owner}", "SK": f"MONTH#{u.month}"},
        UpdateExpression="ADD alerted :a",
        ExpressionAttributeValues={":a": set(labels)},
    )


def profiles_for(user: str, config: dict) -> list[str]:
    return [arn for arn, meta in config.get("profiles", {}).items() if meta.get("owner") == user]


def set_budget_state(user: str, state: str, config: dict) -> None:
    for arn in profiles_for(user, config):
        try:
            _bedrock.tag_resource(resourceARN=arn, tags=[{"key": "budget_state", "value": state}])
        except ClientError as e:
            log.error("tag_resource failed for %s: %s", arn, e)


def notify(subject: str, body: str) -> None:
    if not ALERT_TOPIC_ARN:
        return
    _sns.publish(TopicArn=ALERT_TOPIC_ARN, Subject=subject[:100], Message=body)


def index_analytics(doc: dict) -> None:
    if not ANALYTICS_ENDPOINT:
        return
    url = f"{ANALYTICS_ENDPOINT.rstrip('/')}/bedrock-usage/_doc"
    body = json.dumps(doc).encode()
    req = AWSRequest(method="POST", url=url, data=body, headers={"Content-Type": "application/json"})
    SigV4Auth(_session.get_credentials(), "aoss", _session.region_name).add_auth(req)
    prepared = urllib.request.Request(url, data=body, headers=dict(req.headers), method="POST")
    try:
        urllib.request.urlopen(prepared, timeout=5).read()
    except Exception as e:  # analytics is best-effort
        log.warning("analytics index failed: %s", e)


def handle_budget(u: meter.Usage, totals: dict, budget: dict, config: dict) -> None:
    result = meter.evaluate(totals, budget)
    email = config.get("engineers", {}).get(u.owner, {}).get("email", "")
    if result["new_alerts"]:
        add_alerted(u, [str(t) for t in result["new_alerts"]])
        top = max(result["new_alerts"])
        notify(
            f"[{NAME_PREFIX}] {u.owner} at {result['pct']:.0f}% of monthly AI budget",
            f"Engineer: {u.owner} ({email})\nTeam: {u.team}\nMonth: {u.month}\n"
            f"Spend: ${totals['usd']:.2f} of ${budget['monthly_usd_budget']:.2f} "
            f"({result['pct_usd']:.0f}%)\n"
            f"Tokens: {totals['total_tokens']:,} of {budget['monthly_token_budget']:,} "
            f"({result['pct_tokens']:.0f}%)\nThreshold crossed: {top}%\n"
            + ("Access has been suspended until the 1st or an admin grant.\n" if result["exhausted"] else ""),
        )
    if result["exhausted"] and totals.get("state") != "exhausted":
        set_budget_state(u.owner, "exhausted", config)
        mark(u, state="exhausted")
        log.info("budget exhausted: user=%s pct=%s", u.owner, result["pct"])


def handle_cache(u: meter.Usage, totals: dict, budget: dict, config: dict) -> None:
    window = budget["cache_window_requests"]
    if totals["win_requests"] < window:
        return
    rate = meter.cache_hit_rate(totals["win_input"], totals["win_cache"])
    mark(u, win_requests=0, win_input=0, win_cache=0, cache_hit_rate=Decimal(str(round(rate, 4))))
    if rate >= budget["min_cache_hit_rate"]:
        return
    email = config.get("engineers", {}).get(u.owner, {}).get("email", "")
    already = "cache" in totals.get("alerted", set())
    if not already:
        add_alerted(u, ["cache"])
        notify(
            f"[{NAME_PREFIX}] {u.owner}: prompt caching appears to be OFF",
            f"Engineer: {u.owner} ({email})\nCache hit rate over last {window} requests: {rate:.0%} "
            f"(minimum {budget['min_cache_hit_rate']:.0%}).\n"
            "Cached tokens cost ~10% of uncached input. In Cline: Settings > API Provider > AWS Bedrock > "
            "tick 'Use prompt caching'. See docs/cline-setup.md.\n"
            + ("Access is suspended until an admin runs budget-ctl unlock.\n" if budget["enforce_cache"] else ""),
        )
    if budget["enforce_cache"] and totals.get("state") == "ok":
        set_budget_state(u.owner, "cache_disabled", config)
        mark(u, state="cache_disabled")


def process(records: list[dict], config: dict) -> int:
    processed = 0
    for rec in records:
        u = meter.extract_usage(rec)
        if u is None or not dedupe(u.request_id):
            continue
        meter.enrich(u, config)
        if u.owner == "unknown":
            log.warning("unattributed request %s model=%s", u.request_id, u.model_id)
        eligible = meter.cache_eligible(u)
        totals = record_usage(u, eligible)
        budget = meter.budget_for(u.owner, config, get_override(u.owner))
        handle_budget(u, totals, budget, config)
        handle_cache(u, totals, budget, config)
        index_analytics(meter.analytics_document(u))
        processed += 1
    return processed


def handler(event, context):
    config = load_config()
    records = meter.decode_log_events(event)
    n = process(records, config)
    log.info("processed %d of %d records", n, len(records))
    return {"processed": n}
