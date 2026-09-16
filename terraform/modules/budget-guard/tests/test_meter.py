import base64
import gzip
import json

import meter

PROFILE_ARN = "arn:aws-us-gov:bedrock:us-gov-west-1:000000000000:application-inference-profile/abc123"
CONFIG = {
    "defaults": {
        "monthly_usd_budget": 48,
        "monthly_token_budget": 5_700_000,
        "budget_mode": "usd",
        "enforce": True,
        "alert_thresholds": [50, 80, 100],
        "min_cache_hit_rate": 0.5,
        "enforce_cache": False,
        "cache_window_requests": 20,
    },
    "engineers": {"jane.doe": {"email": "j@x.gov", "team": "platform", "monthly_usd_budget": 96}},
    "profiles": {PROFILE_ARN: {"owner": "jane.doe", "team": "platform", "tier": "opus", "base_model": "anthropic.claude-opus-5"}},
    "prices": {
        "claude-opus-5": {"input": 6.0, "output": 30.0, "cache_write": 7.5, "cache_read": 0.6},
        "default": {"input": 1.0, "output": 1.0, "cache_write": 1.0, "cache_read": 1.0},
    },
}


def _record(**over):
    rec = {
        "schemaType": "ModelInvocationLog",
        "timestamp": "2026-09-16T12:00:00Z",
        "requestId": "req-1",
        "identity": {"arn": "arn:aws-us-gov:sts::000000000000:assumed-role/AWSReservedSSO_bcp-BedrockEngineer_abc/jane.doe"},
        "modelId": PROFILE_ARN,
        "operation": "ConverseStream",
        "input": {"inputTokenCount": 1000, "cacheReadInputTokenCount": 9000, "cacheWriteInputTokenCount": 0},
        "output": {"outputTokenCount": 500},
    }
    rec.update(over)
    return rec


def test_decode_log_events_roundtrip():
    payload = {"logEvents": [{"message": json.dumps(_record())}, {"message": "not json"}]}
    data = base64.b64encode(gzip.compress(json.dumps(payload).encode())).decode()
    recs = meter.decode_log_events({"awslogs": {"data": data}})
    assert len(recs) == 1
    assert recs[0]["requestId"] == "req-1"


def test_user_from_identity():
    assert meter.user_from_identity("arn:aws-us-gov:sts::1:assumed-role/X/jane.doe") == "jane.doe"
    assert meter.user_from_identity("arn:aws:iam::1:user/bob") == "bob"
    assert meter.user_from_identity("") == "unknown"


def test_extract_and_enrich_costs():
    u = meter.extract_usage(_record())
    assert u is not None
    meter.enrich(u, CONFIG)
    assert u.owner == "jane.doe"
    assert u.tier == "opus"
    assert u.total_tokens == 10_500
    # 1000*6 + 9000*0.6 + 500*30 = 6000 + 5400 + 15000 = 26400 micro-dollars-per-million -> $0.0264
    assert abs(u.usd - 0.0264) < 1e-9


def test_extract_ignores_other_schema():
    assert meter.extract_usage({"schemaType": "Other"}) is None


def test_resolve_profile_by_id_suffix():
    meta = meter.resolve_profile("abc123", CONFIG["profiles"])
    assert meta["owner"] == "jane.doe"


def test_budget_override_precedence():
    b = meter.budget_for("jane.doe", CONFIG)
    assert b["monthly_usd_budget"] == 96
    b2 = meter.budget_for("jane.doe", CONFIG, {"monthly_usd_budget": 200, "enforce": False})
    assert b2["monthly_usd_budget"] == 200
    assert b2["enforce"] is False
    b3 = meter.budget_for("nobody", CONFIG)
    assert b3["monthly_usd_budget"] == 48


def test_evaluate_thresholds_and_exhaustion():
    b = meter.budget_for("jane.doe", CONFIG)
    r = meter.evaluate({"usd": 50.0, "total_tokens": 100, "alerted": set()}, b)
    assert r["new_alerts"] == [50]
    assert not r["exhausted"]
    r = meter.evaluate({"usd": 96.5, "total_tokens": 100, "alerted": {"50", "80"}}, b)
    assert r["new_alerts"] == [100]
    assert r["exhausted"]
    b["enforce"] = False
    r = meter.evaluate({"usd": 500, "total_tokens": 100, "alerted": set()}, b)
    assert not r["exhausted"]


def test_evaluate_token_and_either_modes():
    b = meter.budget_for("nobody", CONFIG)
    b["budget_mode"] = "tokens"
    r = meter.evaluate({"usd": 0.0, "total_tokens": 5_700_000, "alerted": set()}, b)
    assert r["pct"] == 100.0
    b["budget_mode"] = "either"
    r = meter.evaluate({"usd": 40.0, "total_tokens": 1_000, "alerted": set()}, b)
    assert r["pct"] > 80


def test_cache_math():
    assert meter.cache_hit_rate(1000, 9000) == 0.9
    assert meter.cache_hit_rate(0, 0) == 0.0
    u = meter.extract_usage(_record(input={"inputTokenCount": 100}))
    assert not meter.cache_eligible(u)
    assert meter.cache_eligible(meter.extract_usage(_record()))


def test_analytics_document_shape():
    u = meter.enrich(meter.extract_usage(_record()), CONFIG)
    d = meter.analytics_document(u)
    assert d["user"] == "jane.doe" and d["total_tokens"] == 10_500 and d["usd"] > 0
