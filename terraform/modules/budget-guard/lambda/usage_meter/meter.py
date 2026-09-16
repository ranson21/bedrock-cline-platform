"""Pure functions for the Budget Guard usage meter.

Kept free of AWS clients so they can be unit tested without network access.
"""

from __future__ import annotations

import base64
import gzip
import json
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any

MONTH_FMT = "%Y-%m"


@dataclass
class Usage:
    request_id: str
    timestamp: str
    user: str
    model_id: str
    operation: str
    input_tokens: int = 0
    output_tokens: int = 0
    cache_read_tokens: int = 0
    cache_write_tokens: int = 0
    # resolved
    owner: str = ""
    team: str = ""
    tier: str = ""
    base_model: str = ""
    usd: float = 0.0
    extra: dict[str, Any] = field(default_factory=dict)

    @property
    def total_tokens(self) -> int:
        return self.input_tokens + self.output_tokens + self.cache_read_tokens + self.cache_write_tokens

    @property
    def month(self) -> str:
        return month_key(self.timestamp)


def month_key(timestamp: str | None) -> str:
    if timestamp:
        try:
            return datetime.fromisoformat(timestamp.replace("Z", "+00:00")).strftime(MONTH_FMT)
        except ValueError:
            pass
    return datetime.now(timezone.utc).strftime(MONTH_FMT)


def decode_log_events(event: dict) -> list[dict]:
    """Decode a CloudWatch Logs subscription payload into invocation-log dicts."""
    raw = base64.b64decode(event["awslogs"]["data"])
    payload = json.loads(gzip.decompress(raw))
    records = []
    for le in payload.get("logEvents", []):
        msg = le.get("message", "")
        if not msg.startswith("{"):
            continue
        try:
            records.append(json.loads(msg))
        except json.JSONDecodeError:
            continue
    return records


def user_from_identity(arn: str) -> str:
    """arn:...:assumed-role/AWSReservedSSO_x_y/jane.doe -> jane.doe"""
    if not arn:
        return "unknown"
    if ":assumed-role/" in arn or ":user/" in arn or ":federated-user/" in arn:
        return arn.rsplit("/", 1)[-1]
    return arn


def extract_usage(rec: dict) -> Usage | None:
    if rec.get("schemaType") != "ModelInvocationLog":
        return None
    inp = rec.get("input") or {}
    out = rec.get("output") or {}
    identity = (rec.get("identity") or {}).get("arn", "")
    return Usage(
        request_id=rec.get("requestId", ""),
        timestamp=rec.get("timestamp", ""),
        user=user_from_identity(identity),
        model_id=rec.get("modelId", ""),
        operation=rec.get("operation", ""),
        input_tokens=int(inp.get("inputTokenCount", 0) or 0),
        output_tokens=int(out.get("outputTokenCount", 0) or 0),
        cache_read_tokens=int(inp.get("cacheReadInputTokenCount", 0) or 0),
        cache_write_tokens=int(inp.get("cacheWriteInputTokenCount", 0) or 0),
        extra={"region": rec.get("region", ""), "identity_arn": identity},
    )


def resolve_profile(model_id: str, profiles: dict[str, dict]) -> dict:
    """Match the invoked model id to an application inference profile entry."""
    if model_id in profiles:
        return profiles[model_id]
    # The log may carry just the profile id rather than the full ARN.
    tail = model_id.rsplit("/", 1)[-1]
    for arn, meta in profiles.items():
        if arn.rsplit("/", 1)[-1] == tail:
            return meta
    return {}


def price_for(base_model: str, prices: dict[str, dict]) -> dict:
    for key, p in prices.items():
        if key != "default" and key in base_model:
            return p
    return prices.get("default", {"input": 0, "output": 0, "cache_write": 0, "cache_read": 0})


def cost_usd(u: Usage, price: dict) -> float:
    return (
        u.input_tokens * float(price.get("input", 0))
        + u.output_tokens * float(price.get("output", 0))
        + u.cache_read_tokens * float(price.get("cache_read", 0))
        + u.cache_write_tokens * float(price.get("cache_write", 0))
    ) / 1_000_000


def enrich(u: Usage, config: dict) -> Usage:
    meta = resolve_profile(u.model_id, config.get("profiles", {}))
    u.owner = meta.get("owner") or u.user
    u.team = meta.get("team", "") or config.get("engineers", {}).get(u.owner, {}).get("team", "")
    u.tier = meta.get("tier", "")
    u.base_model = meta.get("base_model") or u.model_id
    u.usd = cost_usd(u, price_for(u.base_model, config.get("prices", {})))
    return u


def budget_for(user: str, config: dict, override: dict | None = None) -> dict:
    """Effective budget: defaults <- engineers.yaml entry <- DynamoDB override."""
    d = dict(config.get("defaults", {}))
    e = config.get("engineers", {}).get(user, {}) or {}
    b = {
        "monthly_usd_budget": float(e.get("monthly_usd_budget") or d.get("monthly_usd_budget", 39)),
        "monthly_token_budget": int(e.get("monthly_token_budget") or d.get("monthly_token_budget", 10_000_000)),
        "budget_mode": e.get("budget_mode") or d.get("budget_mode", "usd"),
        "enforce": bool(d.get("enforce", True)) if e.get("enforce") is None else bool(e.get("enforce")),
        "alert_thresholds": list(d.get("alert_thresholds", [50, 80, 100])),
        "min_cache_hit_rate": float(d.get("min_cache_hit_rate", 0.5)),
        "enforce_cache": bool(d.get("enforce_cache", False)),
        "cache_window_requests": int(d.get("cache_window_requests", 20)),
    }
    if override:
        for k in ("monthly_usd_budget", "monthly_token_budget", "budget_mode", "enforce", "enforce_cache"):
            if k in override and override[k] is not None:
                b[k] = type(b[k])(override[k]) if not isinstance(b[k], bool) else bool(override[k])
    return b


def evaluate(totals: dict, budget: dict) -> dict:
    """totals: usd, total_tokens, alerted (set of str). Returns percent used and new alerts."""
    usd = float(totals.get("usd", 0))
    tokens = int(totals.get("total_tokens", 0))
    pct_usd = 100.0 * usd / budget["monthly_usd_budget"] if budget["monthly_usd_budget"] else 0.0
    pct_tok = 100.0 * tokens / budget["monthly_token_budget"] if budget["monthly_token_budget"] else 0.0
    mode = budget["budget_mode"]
    if mode == "usd":
        pct = pct_usd
    elif mode == "tokens":
        pct = pct_tok
    else:
        pct = max(pct_usd, pct_tok)
    already = set(totals.get("alerted") or [])
    new_alerts = [t for t in sorted(budget["alert_thresholds"]) if pct >= t and str(t) not in already]
    return {
        "pct": round(pct, 2),
        "pct_usd": round(pct_usd, 2),
        "pct_tokens": round(pct_tok, 2),
        "new_alerts": new_alerts,
        "exhausted": pct >= 100.0 and budget["enforce"],
    }


def cache_hit_rate(win_input: int, win_cache_read: int) -> float:
    denom = win_input + win_cache_read
    return (win_cache_read / denom) if denom else 0.0


def cache_eligible(u: Usage, min_context_tokens: int = 2048) -> bool:
    """Only requests large enough to be cacheable count toward the compliance window."""
    return (u.input_tokens + u.cache_read_tokens) >= min_context_tokens


def analytics_document(u: Usage) -> dict:
    return {
        "@timestamp": u.timestamp,
        "request_id": u.request_id,
        "user": u.owner,
        "team": u.team,
        "tier": u.tier,
        "model": u.base_model,
        "operation": u.operation,
        "input_tokens": u.input_tokens,
        "output_tokens": u.output_tokens,
        "cache_read_tokens": u.cache_read_tokens,
        "cache_write_tokens": u.cache_write_tokens,
        "total_tokens": u.total_tokens,
        "usd": round(u.usd, 6),
        "region": u.extra.get("region", ""),
    }
