"""Strip operator-identifying data from a report before HTTP."""

from __future__ import annotations

import copy
import os
import re
from pathlib import Path
from typing import Any

from .provenance import resolve_test_root
from .schemas import TestReport

REPORT_VERSION = "1.2.0"

SESSION_TYPES = frozenset({"probe", "suite", "plugin", "isolated-daw", "web-manual"})
PREFIX_KINDS = frozenset({"temp-probe", "isolated", "clone", "production", "unknown"})

HOME_PATH = re.compile(r"/(?:home|Users)/[^\s\"'`<>]+")
MAC_ADDRESS = re.compile(r"\b(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}\b")
EMAIL = re.compile(r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b")
COMPUTER_ID = re.compile(r"\bComputerId\s*[=:]\s*\S+", re.IGNORECASE)

_MEASUREMENT_LOG_KEYS = frozenset(
    {"yabridge_log_tail", "yabridge_editor_log_tail"}
)

# Server contract: drafts reject a test whose measurements exceed this many
# JSON nodes (MAX_MEASUREMENT_NODES on the results server). A failing probe
# accumulates retries in its evidence lists and can exceed it several times
# over, which used to make exactly the interesting reports unsubmittable.
_MEASUREMENT_NODE_BUDGET = 2048


def _measurement_nodes(value: Any) -> int:
    if isinstance(value, dict):
        return 1 + sum(_measurement_nodes(item) for item in value.values())
    if isinstance(value, list):
        return 1 + sum(_measurement_nodes(item) for item in value)
    return 1


# Lists at or below this node count are evidence, not bulk (coordinate
# pairs, assertion lists); the trim never touches them.
_MEASUREMENT_TRIM_FLOOR = 16


def _bulkiest_list_path(value: Any) -> tuple[Any, ...] | None:
    """Path of the largest multi-entry list anywhere in the tree, if any
    exceeds the trim floor."""
    best_path: tuple[Any, ...] | None = None
    best_nodes = _MEASUREMENT_TRIM_FLOOR

    def walk(item: Any, path: tuple[Any, ...]) -> None:
        nonlocal best_path, best_nodes
        if isinstance(item, dict):
            for key, child in item.items():
                walk(child, path + (key,))
        elif isinstance(item, list):
            count = _measurement_nodes(item)
            if len(item) > 1 and count > best_nodes:
                best_path, best_nodes = path, count
            for index, child in enumerate(item):
                walk(child, path + (index,))

    walk(value, ())
    return best_path


def _trim_measurements_to_budget(
    measurements: dict[str, Any], budget: int = _MEASUREMENT_NODE_BUDGET
) -> dict[str, Any]:
    """Fit measurements into the server's node budget.

    Repeatedly halves the bulkiest event list anywhere in the tree (keeping
    the oldest entries, which hold the baseline and the first failure) and
    records what was cut in a top-level ``<key>_dropped`` counter. Small
    lists — coordinates, assertions — are never touched. If halving cannot
    reach the budget, the bulkiest top-level container is dropped whole and
    replaced by a ``<key>_dropped_nodes`` marker.
    """
    if _measurement_nodes(measurements) <= budget:
        return measurements

    trimmed = copy.deepcopy(measurements)
    while _measurement_nodes(trimmed) > budget:
        path = _bulkiest_list_path(trimmed)
        if path is not None:
            parent: Any = trimmed
            for step in path[:-1]:
                parent = parent[step]
            entries = parent[path[-1]]
            keep = max(1, len(entries) // 2)
            counter = f"{path[0]}_dropped"
            trimmed[counter] = trimmed.get(counter, 0) + len(entries) - keep
            parent[path[-1]] = entries[:keep]
            continue
        bulkiest = max(
            (
                key
                for key, value in trimmed.items()
                if isinstance(value, (dict, list))
            ),
            key=lambda key: _measurement_nodes(trimmed[key]),
            default=None,
        )
        if bulkiest is None:
            break
        trimmed[f"{bulkiest}_dropped_nodes"] = _measurement_nodes(
            trimmed.pop(bulkiest)
        )
    return trimmed


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
    if cleaned:
        cleaned = _trim_measurements_to_budget(cleaned)
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
    # A repository that is a directory is a path; say "local" and nothing else.
    repo = environment.get("yabridge_repo")
    if isinstance(repo, str) and not re.match(r"^(https://|ssh://|git@)", repo):
        environment["yabridge_repo"] = "local"
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
