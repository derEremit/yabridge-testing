"""Resolve yabridge-managed plugin bridges from metadata targets."""

from __future__ import annotations

import os
import re
from collections.abc import Mapping
from dataclasses import dataclass
from enum import Enum
from pathlib import Path

from .provenance import StagingIdentity
from .schemas import PluginType

LOCATION_LINE = re.compile(
    r"^(?P<label>VST2|VST3|CLAP) location: '(?P<path>[^']*)'\s*$"
)
PLUGIN_STATUS_LINE = re.compile(
    r"^\s+(?P<name>[^:]+?) :: (?P<kind>VST2|VST3|CLAP), (?P<rest>.+)$"
)
LOCATION_LABELS = {
    "VST2": PluginType.VST2,
    "VST3": PluginType.VST3,
    "CLAP": PluginType.CLAP,
}
KIND_LABELS = {
    "VST2": PluginType.VST2,
    "VST3": PluginType.VST3,
    "CLAP": PluginType.CLAP,
}


class PluginSyncState(str, Enum):
    """Synchronization state reported by yabridgectl for one plugin."""

    SYNCED = "synced"
    COPY = "copy"
    ERROR = "error"


@dataclass(frozen=True)
class BridgeRecord:
    """A Windows plugin and its validated native yabridge bridge."""

    windows_path: Path
    bridge_path: Path
    plugin_type: PluginType


@dataclass(frozen=True)
class StatusPluginRecord:
    """One Windows plugin entry parsed from yabridgectl status."""

    windows_path: Path
    plugin_type: PluginType
    sync_state: PluginSyncState
    plugin_directory: Path
    bridge_root: Path | None


@dataclass(frozen=True)
class YabridgectlStatus:
    """Structured parse of human-readable yabridgectl status output."""

    bridge_roots: tuple[tuple[PluginType, Path], ...]
    plugins: tuple[StatusPluginRecord, ...]


def discover_bridge(
    plugin_path: Path | str,
    plugin_type: PluginType,
    environ: Mapping[str, str],
    staging_identity: StagingIdentity | None,
    *,
    status_text: str | None = None,
) -> BridgeRecord | None:
    """Find the managed bridge for an exact canonical Windows plugin path."""
    canonical = _canonicalize_windows_path(plugin_path)
    if canonical is None:
        return None

    parsed_status = (
        parse_yabridgectl_status(status_text) if status_text is not None else None
    )
    roots = _collect_bridge_roots(
        environ, staging_identity, plugin_type, parsed_status
    )
    matches: list[BridgeRecord] = []
    for root in roots:
        record = _scan_bridge_root(root, canonical, plugin_type)
        if record is not None:
            matches.append(record)

    if len(matches) != 1:
        return None
    return matches[0]


def parse_yabridgectl_status(text: str) -> YabridgectlStatus:
    """Parse yabridgectl status into structured Windows-side plugin records."""
    bridge_roots: dict[PluginType, Path] = {}
    plugins: list[StatusPluginRecord] = []
    current_directory: Path | None = None

    for line in text.splitlines():
        location_match = LOCATION_LINE.match(line)
        if location_match is not None:
            label = location_match.group("label")
            plugin_type = LOCATION_LABELS[label]
            path = Path(location_match.group("path"))
            if path.is_absolute():
                bridge_roots[plugin_type] = path
            current_directory = None
            continue

        stripped = line.strip()
        if stripped and not line.startswith(" ") and stripped.endswith("/"):
            current_directory = Path(stripped.rstrip("/"))
            continue

        status_match = PLUGIN_STATUS_LINE.match(line)
        if status_match is None or current_directory is None:
            continue

        kind = status_match.group("kind")
        if kind not in KIND_LABELS:
            continue
        plugin_type = KIND_LABELS[kind]

        sync_state = _parse_sync_state(status_match.group("rest"))
        if sync_state is None:
            continue

        plugins.append(
            StatusPluginRecord(
                windows_path=current_directory / status_match.group("name"),
                plugin_type=plugin_type,
                sync_state=sync_state,
                plugin_directory=current_directory,
                bridge_root=bridge_roots.get(plugin_type),
            )
        )

    return YabridgectlStatus(
        bridge_roots=tuple(bridge_roots.items()),
        plugins=tuple(plugins),
    )


def status_corroborates_bridge(
    status: YabridgectlStatus,
    record: BridgeRecord,
) -> bool:
    """Return whether parsed status corroborates one filesystem bridge record."""
    windows_path = record.windows_path.resolve()

    for entry in status.plugins:
        try:
            candidate = entry.windows_path.resolve()
        except OSError:
            candidate = entry.windows_path

        if candidate != windows_path or entry.plugin_type != record.plugin_type:
            continue

        return entry.sync_state in {PluginSyncState.SYNCED, PluginSyncState.COPY}

    return False


def _parse_sync_state(rest: str) -> PluginSyncState | None:
    parts = [part.strip() for part in rest.split(",") if part.strip()]
    if not parts:
        return None

    terminal = parts[-1].lower()
    if terminal == "synced":
        return PluginSyncState.SYNCED
    if terminal == "copy":
        return PluginSyncState.COPY
    if terminal == "error":
        return PluginSyncState.ERROR
    return None


def _canonicalize_windows_path(plugin_path: Path | str) -> Path | None:
    path = Path(plugin_path)
    try:
        return path.resolve()
    except OSError:
        return None


def _collect_bridge_roots(
    environ: Mapping[str, str],
    staging_identity: StagingIdentity | None,
    plugin_type: PluginType,
    parsed_status: YabridgectlStatus | None,
) -> list[Path]:
    roots: list[Path] = []
    seen: set[Path] = set()

    def add_root(raw: str | Path) -> None:
        path = Path(raw)
        if not path.is_absolute():
            return
        try:
            resolved = path.resolve()
        except OSError:
            return
        if resolved in seen or not resolved.is_dir():
            return
        seen.add(resolved)
        roots.append(resolved)

    env_key = {
        PluginType.VST2: "VST_PATH",
        PluginType.VST3: "VST3_PATH",
        PluginType.CLAP: "CLAP_PATH",
    }[plugin_type]
    env_value = environ.get(env_key, "")
    if env_value:
        for part in env_value.split(os.pathsep):
            if part:
                add_root(part)

    if staging_identity is not None and staging_identity.bridge_roots:
        for root in staging_identity.bridge_roots:
            add_root(root)

    if parsed_status is not None:
        for root_type, root in parsed_status.bridge_roots:
            if root_type == plugin_type:
                add_root(root)

    return roots


def _scan_bridge_root(
    root: Path,
    canonical_windows_path: Path,
    plugin_type: PluginType,
) -> BridgeRecord | None:
    matches: list[BridgeRecord] = []
    for metadata in _iter_windows_metadata(root, plugin_type):
        target = _resolve_symlink_target(metadata)
        if target is None or target != canonical_windows_path:
            continue
        bridge_path = _native_bridge_for_metadata(metadata, plugin_type)
        if bridge_path is None or not bridge_path.is_file():
            continue
        matches.append(
            BridgeRecord(
                windows_path=canonical_windows_path,
                bridge_path=bridge_path.resolve(),
                plugin_type=plugin_type,
            )
        )

    if len(matches) != 1:
        return None
    return matches[0]


def _iter_windows_metadata(root: Path, plugin_type: PluginType) -> list[Path]:
    if not root.is_dir():
        return []

    entries: list[Path] = []
    if plugin_type == PluginType.VST2:
        entries.extend(path for path in root.glob("*.dll") if path.is_symlink())
    elif plugin_type == PluginType.CLAP:
        entries.extend(path for path in root.glob("*.clap-win") if path.is_symlink())
    elif plugin_type == PluginType.VST3:
        for pattern in ("*/Contents/x86_64-win/*", "*/Contents/x86-win/*"):
            entries.extend(path for path in root.glob(pattern) if path.is_symlink())
    return entries


def _resolve_symlink_target(path: Path) -> Path | None:
    if not path.is_symlink():
        return None
    try:
        return path.resolve()
    except OSError:
        return None


def _native_bridge_for_metadata(metadata: Path, plugin_type: PluginType) -> Path | None:
    if plugin_type == PluginType.VST2:
        bridge = metadata.with_suffix(".so")
    elif plugin_type == PluginType.CLAP:
        bridge = metadata.with_name(f"{metadata.stem}.clap")
    elif plugin_type == PluginType.VST3:
        bundle_root = metadata.parents[2]
        plugin_name = metadata.stem
        if metadata.parent.name not in {"x86-win", "x86_64-win"}:
            return None
        candidates = [
            bundle_root / "Contents" / native_arch / f"{plugin_name}.so"
            for native_arch in ("x86_64-linux", "i386-linux")
        ]
        existing = [candidate for candidate in candidates if candidate.is_file()]
        if len(existing) != 1:
            return None
        bridge = existing[0]
    else:
        return None

    return bridge if bridge.is_file() else None
