"""Staging provenance parsing."""

from __future__ import annotations

import json
import re
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Any

STATE_LINE = re.compile(r"^(?P<key>[A-Z0-9_]+)=(?P<value>[A-Za-z0-9._:/+@-]+)$")
COMMIT = re.compile(r"^[0-9a-fA-F]{40}$")

MANIFEST_SCHEMA_VERSION = 1


class ProvenanceError(Exception):
    """Invalid or inconsistent staging provenance."""


@dataclass(frozen=True)
class StagingIdentity:
    """Verified yabridge ref and commit from staging root files."""

    ref: str
    commit: str
    bridge_roots: tuple[Path, ...] | None = None

    @classmethod
    def load(cls, root: Path) -> StagingIdentity | None:
        """Load staging identity from explicit root, never scanning parents."""
        state_path = root / "build" / "component-state.env"
        manifest_path = root / "run-state" / "run-manifest.json"

        component_state = _parse_component_state(state_path) if state_path.is_file() else None
        manifest_present = manifest_path.is_file()

        if manifest_present:
            manifest = _parse_manifest(manifest_path)
            if component_state is not None:
                _assert_manifest_matches_state(manifest, component_state)
            return cls(
                ref=manifest["yabridge_requested_ref"],
                commit=manifest["yabridge_commit"],
                bridge_roots=manifest.get("bridge_roots"),
            )

        if component_state is not None:
            return cls(
                ref=component_state["YABRIDGE_REF"],
                commit=component_state["YABRIDGE_COMMIT"],
            )

        return None


def _parse_component_state(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    try:
        content = path.read_text()
    except OSError as exc:
        raise ProvenanceError(f"cannot read component state: {path}") from exc

    for line in content.splitlines():
        match = STATE_LINE.match(line)
        if match is None:
            continue
        values[match.group("key")] = match.group("value")

    ref = values.get("YABRIDGE_REF")
    commit = values.get("YABRIDGE_COMMIT")
    if ref is None or commit is None:
        raise ProvenanceError("component state missing YABRIDGE_REF or YABRIDGE_COMMIT")
    if not COMMIT.match(commit):
        raise ProvenanceError("component state YABRIDGE_COMMIT is not a valid commit hash")

    return {"YABRIDGE_REF": ref, "YABRIDGE_COMMIT": commit}


def _parse_manifest(path: Path) -> dict[str, Any]:
    try:
        content = path.read_text()
    except OSError as exc:
        raise ProvenanceError(f"cannot read run manifest: {path}") from exc

    try:
        document = json.loads(content)
    except json.JSONDecodeError as exc:
        raise ProvenanceError(f"run manifest is not valid JSON: {path}") from exc

    if not isinstance(document, dict):
        raise ProvenanceError("run manifest must be a JSON object")

    schema_version = document.get("schema_version")
    if schema_version != MANIFEST_SCHEMA_VERSION:
        raise ProvenanceError(
            f"unsupported run manifest schema_version: {schema_version!r}"
        )

    ref = document.get("yabridge_requested_ref")
    commit = document.get("yabridge_commit")
    if not isinstance(ref, str) or not ref:
        raise ProvenanceError("run manifest missing yabridge_requested_ref")
    if not isinstance(commit, str) or not COMMIT.match(commit):
        raise ProvenanceError("run manifest yabridge_commit is not a valid commit hash")

    bridge_roots = _parse_bridge_roots(document.get("bridge_roots"))

    return {
        "yabridge_requested_ref": ref,
        "yabridge_commit": commit,
        "bridge_roots": bridge_roots,
        "raw": document,
    }


def _parse_bridge_roots(value: object) -> tuple[Path, ...] | None:
    if value is None:
        return None
    if not isinstance(value, list):
        raise ProvenanceError("run manifest bridge_roots must be a list")

    roots: list[Path] = []
    for index, entry in enumerate(value):
        if not isinstance(entry, str) or not entry:
            raise ProvenanceError(f"run manifest bridge_roots[{index}] is invalid")
        path = Path(entry)
        if not path.is_absolute():
            raise ProvenanceError(f"run manifest bridge_roots[{index}] is not absolute")
        roots.append(path)

    return tuple(roots) if roots else None


def _assert_manifest_matches_state(
    manifest: Mapping[str, Any],
    component_state: Mapping[str, str],
) -> None:
    if manifest["yabridge_commit"] != component_state["YABRIDGE_COMMIT"]:
        raise ProvenanceError(
            "run manifest yabridge_commit does not match component state YABRIDGE_COMMIT"
        )
    if manifest["yabridge_requested_ref"] != component_state["YABRIDGE_REF"]:
        raise ProvenanceError(
            "run manifest yabridge_requested_ref does not match component state YABRIDGE_REF"
        )


def resolve_test_root(environ: Mapping[str, str]) -> Path | None:
    """Return YABRIDGE_TEST_ROOT when explicitly set."""
    root = environ.get("YABRIDGE_TEST_ROOT")
    if not root:
        return None
    return Path(root)


@dataclass(frozen=True)
class SessionScalars:
    """Public-safe scalars from a run-manifest. No path fields."""

    wine_version: str | None = None
    wine_sha256: str | None = None
    wine_digest_verified: bool | None = None
    yabridge_commit: str | None = None
    yabridge_ref: str | None = None
    host: str | None = None


def load_session_scalars(root: Path) -> SessionScalars | None:
    """Read wine / yabridge / DAW basename from the run-manifest.

    Path fields (clone, source, bridges, executables) are not returned.
    """
    manifest_path = root / "run-state" / "run-manifest.json"
    if not manifest_path.is_file():
        return None

    document = _parse_manifest(manifest_path)
    raw = document.get("raw") or {}

    wine_version = _optional_text(
        raw.get("wine_version_string")
    ) or _optional_text(raw.get("wine_installed_version"))
    wine_sha256 = _optional_text(raw.get("wine_sha256"))
    digest = raw.get("wine_digest_verified")
    wine_digest_verified = digest if isinstance(digest, bool) else None

    daw = raw.get("daw_executable")
    host = Path(daw).name if isinstance(daw, str) and daw else None

    return SessionScalars(
        wine_version=wine_version,
        wine_sha256=wine_sha256,
        wine_digest_verified=wine_digest_verified,
        yabridge_commit=document.get("yabridge_commit"),
        yabridge_ref=document.get("yabridge_requested_ref"),
        host=host,
    )


def _optional_text(value: object) -> str | None:
    if isinstance(value, str) and value:
        return value
    return None
