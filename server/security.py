"""Shared security and policy helpers for ClawRelay."""

from __future__ import annotations

import json
import logging
import os
import re
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

logger = logging.getLogger(__name__)

MEETING_ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,80}$")

RAW_RETENTION_HOURS = int(os.environ.get("CONTEXT_BRIDGE_RAW_RETENTION_HOURS", "48"))
MEETING_CONTEXT_RETENTION_HOURS = int(
    os.environ.get("CONTEXT_BRIDGE_MEETING_CONTEXT_RETENTION_HOURS", str(RAW_RETENTION_HOURS))
)
PARTICIPANT_PROFILE_RETENTION_DAYS = int(
    os.environ.get("CONTEXT_BRIDGE_PARTICIPANT_PROFILE_RETENTION_DAYS", "30")
)
MEETING_SUMMARY_RETENTION_DAYS = int(
    os.environ.get("CONTEXT_BRIDGE_MEETING_SUMMARY_RETENTION_DAYS", "30")
)
DIGEST_RETENTION_DAYS = int(os.environ.get("CONTEXT_BRIDGE_DIGEST_RETENTION_DAYS", "30"))

EGRESS_POLICY_FILE = Path(
    os.environ.get(
        "CONTEXT_BRIDGE_EGRESS_POLICY_FILE",
        str(Path(os.environ.get("CONTEXT_BRIDGE_DB", "/home/user/clawrelay/data/context-bridge.db")).parent / "egress-policy.json"),
    )
)

CLIENT_TOKEN_ENVS = {
    "daemon": "CONTEXT_BRIDGE_DAEMON_WRITE_TOKEN",
    "helper": "CONTEXT_BRIDGE_HELPER_TOKEN",
    "agent": "CONTEXT_BRIDGE_AGENT_TOKEN",
}


def auth_tokens() -> dict[str, str]:
    tokens: dict[str, str] = {}
    for client, env_name in CLIENT_TOKEN_ENVS.items():
        token = os.environ.get(env_name, "").strip()
        if token:
            tokens[client] = token
    return tokens


def validate_meeting_id(meeting_id: str) -> bool:
    return bool(meeting_id and MEETING_ID_RE.fullmatch(meeting_id))


def safe_meeting_dir(base_dir: Path, meeting_id: str) -> Path:
    if not validate_meeting_id(meeting_id):
        raise ValueError("invalid meeting_id")

    base = base_dir.resolve()
    target = (base / meeting_id).resolve(strict=False)
    if target.parent != base:
        raise ValueError("meeting_id escapes storage root")
    return target


def _load_json_file(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    try:
        with path.open() as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except Exception:
        logger.exception("Failed to load JSON policy file %s", path)
        return {}


def load_egress_policy() -> dict[str, set[str]]:
    data = _load_json_file(EGRESS_POLICY_FILE)
    return {
        "allowed_meeting_ids": set(data.get("allowed_meeting_ids", [])),
        "allowed_google_doc_ids": set(data.get("allowed_google_doc_ids", [])),
        "allowed_google_doc_prefixes": set(data.get("allowed_google_doc_prefixes", [])),
    }


def is_external_meeting_processing_allowed(meeting_id: str, explicit_flag: bool | None) -> bool:
    if explicit_flag is True:
        return True
    if explicit_flag is False:
        return False
    policy = load_egress_policy()
    return meeting_id in policy["allowed_meeting_ids"]


def is_google_doc_fetch_allowed(url: str, doc_id: str | None) -> bool:
    if not url or not doc_id:
        return False
    policy = load_egress_policy()
    if doc_id in policy["allowed_google_doc_ids"]:
        return True
    return any(url.startswith(prefix) for prefix in policy["allowed_google_doc_prefixes"])


def redact_text(text: str, limit: int) -> str:
    value = (text or "").strip()
    if not value:
        return ""
    redacted = re.sub(r"\b[\w\.-]+@[\w\.-]+\.\w+\b", "[REDACTED_EMAIL]", value)
    redacted = re.sub(r"\b(?:\+?\d[\d\s().-]{6,}\d)\b", "[REDACTED_PHONE]", redacted)
    return redacted[:limit]


def summarize_transcript_segments(segments: list[dict[str, Any]], max_segments: int = 100) -> list[dict[str, Any]]:
    trimmed: list[dict[str, Any]] = []
    for segment in segments[:max_segments]:
        trimmed.append(
            {
                "timestamp": segment.get("timestamp", 0),
                "speaker": redact_text(str(segment.get("speaker", "unknown")), 40),
                "text": redact_text(str(segment.get("text", "")), 280),
                "confidence": segment.get("confidence", 1.0),
            }
        )
    return trimmed


def utc_cutoff_hours(hours: int) -> str:
    return (datetime.now(timezone.utc) - timedelta(hours=hours)).isoformat()


def utc_cutoff_days(days: int) -> str:
    return (datetime.now(timezone.utc) - timedelta(days=days)).isoformat()
