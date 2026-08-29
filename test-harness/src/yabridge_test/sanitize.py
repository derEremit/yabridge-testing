"""Strip operator-identifying data from a report before HTTP."""

from __future__ import annotations

import os
import re
from pathlib import Path
from typing import Any

from .provenance import resolve_test_root
from .schemas import TestReport

REPORT_VERSION = "1.1.0"

SESSION_TYPES = frozenset({"probe", "suite", "plugin", "isolated-daw", "web-manual"})
PREFIX_KINDS = frozenset({"temp-probe", "isolated", "clone", "production", "unknown"})

HOME_PATH = re.compile(r"/(?:home|Users)/[^\s\"'`<>]+")
MAC_ADDRESS = re.compile(r"\b(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}\b")
EMAIL = re.compile(r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b")
COMPUTER_ID = re.compile(r"\bComputerId\s*[=:]\s*\S+", re.IGNORECASE)

_MEASUREMENT_LOG_KEYS = frozenset(
    {"yabridge_log_tail", "yabridge_editor_log_tail"}
)


def classify_wine_prefix_kind(
    prefix: str | None,
    *,
    test_root: Path | None = None,
) -> str:
    """Derive a public prefix class from a local path. Never send the path."""
    if not prefix:
        return "unknown"

    path = Path(prefix)
    try:
        resolved = path.resolve()
    except OSError:
        resolved = path

    if resolved.name.startswith("yabridge-probe-prefix-"):
        return "temp-probe"

    if test_root is not None:
        try:
            root = test_root.resolve()
        except OSError:
            root = Path(test_root)
        isolated = root / "prefix"
        clone = root / "prefix-copy"
        if resolved == isolated or path == isolated:
            return "isolated"
        if resolved == clone or path == clone:
            return "clone"
        try:
            resolved.relative_to(root)
        except ValueError:
            return "production"
        return "unknown"

    try:
        if resolved == (Path.home() / ".wine").resolve():
            return "production"
    except OSError:
        pass
    return "unknown"


def redact_text(value: str) -> str:
    """Replace home paths, MACs, emails, and ComputerId with placeholders."""
    redacted = HOME_PATH.sub("[path]", value)
    redacted = MAC_ADDRESS.sub("[mac]", redacted)
    redacted = EMAIL.sub("[email]", redacted)
    return COMPUTER_ID.sub("ComputerId=[id]", redacted)


def _redact_value(value: Any) -> Any:
    if isinstance(value, str):
        return redact_text(value)
    if isinstance(value, list):
        return [_redact_value(item) for item in value]
    if isinstance(value, dict):
        return {key: _redact_value(item) for key, item in value.items()}
    return value


def _sanitize_measurements(measurements: dict[str, Any] | None) -> dict[str, Any] | None:
    if not measurements:
        return measurements

    cleaned: dict[str, Any] = {}
    for key, value in measurements.items():
        if key in _MEASUREMENT_LOG_KEYS:
            continue
        if key == "yabridge" and isinstance(value, dict):
            identity = {
                field: value[field]
                for field in ("sha256", "mode", "version")
                if field in value
            }
            if identity:
                cleaned[key] = _redact_value(identity)
            continue
        cleaned[key] = _redact_value(value)
    return cleaned or None


def payload_for_submit(report: TestReport) -> dict[str, Any]:
    """Return the JSON object that is POSTed to /api/v1/drafts.

    Home paths, prefix paths, plugin paths, log tails, MACs, emails, and
    ComputerId values do not survive this function.
    """
    payload = report.model_dump(mode="json")
    payload["report_version"] = REPORT_VERSION

    session_type = payload.get("session_type")
    if session_type not in SESSION_TYPES:
        payload.pop("session_type", None)

    environment = payload.get("environment") or {}
    prefix = environment.pop("wine_prefix", None)
    kind = environment.get("wine_prefix_kind")
    if kind not in PREFIX_KINDS:
        environment["wine_prefix_kind"] = classify_wine_prefix_kind(
            prefix,
            test_root=resolve_test_root(os.environ),
        )
    payload["environment"] = _redact_value(environment)

    plugin = payload.get("plugin")
    if isinstance(plugin, dict):
        plugin.pop("path", None)
        payload["plugin"] = _redact_value(plugin)

    tests = []
    for test in payload.get("tests") or []:
        if not isinstance(test, dict):
            continue
        test = dict(test)
        if test.get("details"):
            test["details"] = redact_text(str(test["details"]))
        if test.get("error"):
            test["error"] = redact_text(str(test["error"]))
        test["measurements"] = _sanitize_measurements(test.get("measurements"))
        tests.append(_redact_value(test))
    payload["tests"] = tests

    if payload.get("logs"):
        payload["logs"] = redact_text(str(payload["logs"]))
        if "/home/" in payload["logs"] or "/Users/" in payload["logs"]:
            payload["logs"] = None
    if payload.get("notes"):
        payload["notes"] = redact_text(str(payload["notes"]))

    payload.pop("submitter_contact", None)

    return payload
