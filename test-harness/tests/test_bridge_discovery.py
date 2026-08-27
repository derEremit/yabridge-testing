"""Tests for yabridge-managed bridge discovery."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from yabridge_test.bridge_discovery import (
    BridgeRecord,
    PluginSyncState,
    StatusPluginRecord,
    YabridgectlStatus,
    discover_bridge,
    parse_yabridgectl_status,
    status_corroborates_bridge,
)
from yabridge_test.provenance import StagingIdentity
from yabridge_test.schemas import PluginType
from yabridge_test.tests.plugin_load import PluginLoadTest

VALID_COMMIT = "48ea9749b682c48875366134a42073d6b3d0a8c4"
VALID_REF = "master"


def write_manifest_with_roots(
    root: Path,
    bridge_roots: list[str],
    *,
    ref: str = VALID_REF,
    commit: str = VALID_COMMIT,
) -> None:
    manifest_dir = root / "run-state"
    manifest_dir.mkdir(parents=True)
    manifest = {
        "schema_version": 1,
        "yabridge_requested_ref": ref,
        "yabridge_commit": commit,
        "bridge_roots": bridge_roots,
    }
    (manifest_dir / "run-manifest.json").write_text(json.dumps(manifest) + "\n")


def create_vst2_bridge(
    bridge_root: Path,
    clone_root: Path,
    name: str = "Good",
) -> tuple[Path, Path]:
    bridge_root.mkdir(parents=True, exist_ok=True)
    windows_plugin = clone_root / f"{name}.dll"
    windows_plugin.parent.mkdir(parents=True, exist_ok=True)
    windows_plugin.write_bytes(b"vst2")

    metadata = bridge_root / f"{name}.dll"
    native = bridge_root / f"{name}.so"
    metadata.symlink_to(windows_plugin)
    native.write_bytes(b"chainloader")
    return windows_plugin, native


def create_clap_bridge(
    bridge_root: Path,
    clone_root: Path,
    name: str = "Good",
) -> tuple[Path, Path]:
    bridge_root.mkdir(parents=True, exist_ok=True)
    windows_plugin = clone_root / f"{name}.clap"
    windows_plugin.parent.mkdir(parents=True, exist_ok=True)
    windows_plugin.write_bytes(b"clap")

    metadata = bridge_root / f"{name}.clap-win"
    native = bridge_root / f"{name}.clap"
    metadata.symlink_to(windows_plugin)
    native.write_bytes(b"chainloader")
    return windows_plugin, native


def create_vst3_bridge(
    bridge_root: Path,
    clone_root: Path,
    name: str = "Good",
) -> tuple[Path, Path]:
    bridge_root.mkdir(parents=True, exist_ok=True)
    windows_plugin = clone_root / f"{name}.vst3"
    windows_plugin.parent.mkdir(parents=True, exist_ok=True)
    windows_plugin.write_bytes(b"vst3")

    bundle = bridge_root / f"{name}.vst3"
    win_meta = bundle / "Contents" / "x86_64-win" / f"{name}.vst3"
    linux_native = bundle / "Contents" / "x86_64-linux" / f"{name}.so"
    win_meta.parent.mkdir(parents=True, exist_ok=True)
    linux_native.parent.mkdir(parents=True, exist_ok=True)
    win_meta.symlink_to(windows_plugin)
    linux_native.write_bytes(b"chainloader")
    return windows_plugin, linux_native


def create_vst3_32_bridge(
    bridge_root: Path,
    clone_root: Path,
    name: str = "Good32",
) -> tuple[Path, Path]:
    bridge_root.mkdir(parents=True, exist_ok=True)
    windows_plugin = clone_root / f"{name}.vst3"
    windows_plugin.parent.mkdir(parents=True, exist_ok=True)
    windows_plugin.write_bytes(b"vst3-32")

    bundle = bridge_root / f"{name}.vst3"
    win_meta = bundle / "Contents" / "x86-win" / f"{name}.vst3"
    linux_native = bundle / "Contents" / "i386-linux" / f"{name}.so"
    win_meta.parent.mkdir(parents=True, exist_ok=True)
    linux_native.parent.mkdir(parents=True, exist_ok=True)
    win_meta.symlink_to(windows_plugin)
    linux_native.write_bytes(b"chainloader-32")
    return windows_plugin, linux_native


def create_vst3_bridge_with_architectures(
    bridge_root: Path,
    clone_root: Path,
    metadata_arch: str,
    native_arch: str,
    name: str,
) -> tuple[Path, Path]:
    bridge_root.mkdir(parents=True, exist_ok=True)
    windows_plugin = clone_root / f"{name}.vst3"
    windows_plugin.parent.mkdir(parents=True, exist_ok=True)
    windows_plugin.write_bytes(b"vst3")

    bundle = bridge_root / f"{name}.vst3"
    metadata = bundle / "Contents" / metadata_arch / f"{name}.vst3"
    native = bundle / "Contents" / native_arch / f"{name}.so"
    metadata.parent.mkdir(parents=True, exist_ok=True)
    native.parent.mkdir(parents=True, exist_ok=True)
    metadata.symlink_to(windows_plugin)
    native.write_bytes(b"chainloader")
    return windows_plugin, native


@pytest.mark.parametrize(
    ("factory", "plugin_type", "env_key"),
    [
        (create_vst2_bridge, PluginType.VST2, "VST_PATH"),
        (create_clap_bridge, PluginType.CLAP, "CLAP_PATH"),
        (create_vst3_bridge, PluginType.VST3, "VST3_PATH"),
    ],
)
def test_discover_bridge_from_env_path(
    tmp_path: Path,
    factory,
    plugin_type: PluginType,
    env_key: str,
) -> None:
    clone = tmp_path / "clone"
    bridge_root = tmp_path / "bridge"
    windows_plugin, native_bridge = factory(bridge_root, clone)

    record = discover_bridge(
        windows_plugin,
        plugin_type,
        {env_key: str(bridge_root)},
        None,
    )

    assert record == BridgeRecord(
        windows_path=windows_plugin.resolve(),
        bridge_path=native_bridge.resolve(),
        plugin_type=plugin_type,
    )


def test_discovers_32_bit_vst3_bridge_from_i386_linux_bundle(tmp_path: Path) -> None:
    clone = tmp_path / "clone"
    bridge_root = tmp_path / "bridge"
    windows_plugin, native_bridge = create_vst3_32_bridge(bridge_root, clone)

    record = discover_bridge(
        windows_plugin,
        PluginType.VST3,
        {"VST3_PATH": str(bridge_root)},
        None,
    )

    assert record == BridgeRecord(
        windows_path=windows_plugin.resolve(),
        bridge_path=native_bridge.resolve(),
        plugin_type=PluginType.VST3,
    )


def test_discovers_x86_vst3_metadata_with_x86_64_linux_chainloader(
    tmp_path: Path,
) -> None:
    clone = tmp_path / "clone"
    bridge_root = tmp_path / "bridge"
    windows_plugin, native_bridge = create_vst3_bridge_with_architectures(
        bridge_root,
        clone,
        "x86-win",
        "x86_64-linux",
        "GoodCross",
    )

    record = discover_bridge(
        windows_plugin,
        PluginType.VST3,
        {"VST3_PATH": str(bridge_root)},
        None,
    )

    assert record == BridgeRecord(
        windows_path=windows_plugin.resolve(),
        bridge_path=native_bridge.resolve(),
        plugin_type=PluginType.VST3,
    )


def test_discovers_x86_64_vst3_metadata_with_i386_linux_chainloader(
    tmp_path: Path,
) -> None:
    clone = tmp_path / "clone"
    bridge_root = tmp_path / "bridge"
    windows_plugin, native_bridge = create_vst3_bridge_with_architectures(
        bridge_root,
        clone,
        "x86_64-win",
        "i386-linux",
        "GoodCross",
    )

    record = discover_bridge(
        windows_plugin,
        PluginType.VST3,
        {"VST3_PATH": str(bridge_root)},
        None,
    )

    assert record == BridgeRecord(
        windows_path=windows_plugin.resolve(),
        bridge_path=native_bridge.resolve(),
        plugin_type=PluginType.VST3,
    )


def test_rejects_vst3_bundle_with_both_native_architectures(tmp_path: Path) -> None:
    clone = tmp_path / "clone"
    bridge_root = tmp_path / "bridge"
    windows_plugin, native_bridge = create_vst3_bridge_with_architectures(
        bridge_root,
        clone,
        "x86-win",
        "x86_64-linux",
        "Ambiguous",
    )
    second_native = (
        native_bridge.parents[1] / "i386-linux" / native_bridge.name
    )
    second_native.parent.mkdir(parents=True)
    second_native.write_bytes(b"other-chainloader")

    assert (
        discover_bridge(
            windows_plugin,
            PluginType.VST3,
            {"VST3_PATH": str(bridge_root)},
            None,
        )
        is None
    )


def test_rejects_32_bit_vst3_native_bridge_in_windows_metadata_directory(
    tmp_path: Path,
) -> None:
    clone = tmp_path / "clone"
    bridge_root = tmp_path / "bridge"
    windows_plugin, _native_bridge = create_vst3_32_bridge(bridge_root, clone)
    bundle = bridge_root / "Good32.vst3"
    wrong_native = bundle / "Contents" / "x86-win" / "Good32.so"
    wrong_native.write_bytes(b"wrong-directory")
    (bundle / "Contents" / "i386-linux" / "Good32.so").unlink()

    assert (
        discover_bridge(
            windows_plugin,
            PluginType.VST3,
            {"VST3_PATH": str(bridge_root)},
            None,
        )
        is None
    )


def test_discover_bridge_from_manifest_bridge_roots(tmp_path: Path) -> None:
    staging = tmp_path / "staging"
    clone = tmp_path / "clone"
    bridge_root = tmp_path / "home" / ".vst" / "yabridge"
    windows_plugin, native_bridge = create_vst2_bridge(bridge_root, clone)
    write_manifest_with_roots(staging, [str(bridge_root.resolve())])

    identity = StagingIdentity.load(staging)
    assert identity is not None
    assert identity.bridge_roots == (bridge_root.resolve(),)

    record = discover_bridge(windows_plugin, PluginType.VST2, {}, identity)
    assert record == BridgeRecord(
        windows_path=windows_plugin.resolve(),
        bridge_path=native_bridge.resolve(),
        plugin_type=PluginType.VST2,
    )


def test_discover_bridge_from_status_locations(tmp_path: Path) -> None:
    clone = tmp_path / "clone"
    bridge_root = tmp_path / "home" / ".clap" / "yabridge"
    windows_plugin, native_bridge = create_clap_bridge(bridge_root, clone)

    status_text = "\n".join(
        [
            "yabridge path: <auto>",
            f"CLAP location: '{bridge_root}'",
            "",
            f"{clone}/",
            "  Good.clap :: CLAP, 64-bit, synced",
        ]
    )

    record = discover_bridge(
        windows_plugin,
        PluginType.CLAP,
        {},
        None,
        status_text=status_text,
    )

    assert record == BridgeRecord(
        windows_path=windows_plugin.resolve(),
        bridge_path=native_bridge.resolve(),
        plugin_type=PluginType.CLAP,
    )


def test_rejects_broken_metadata_symlink(tmp_path: Path) -> None:
    bridge_root = tmp_path / "bridge"
    clone = tmp_path / "clone"
    bridge_root.mkdir(parents=True)
    windows_plugin = clone / "Good.dll"
    windows_plugin.parent.mkdir(parents=True)
    windows_plugin.write_bytes(b"vst2")
    (bridge_root / "Good.dll").symlink_to(clone / "missing.dll")
    (bridge_root / "Good.so").write_bytes(b"chainloader")

    assert discover_bridge(
        windows_plugin,
        PluginType.VST2,
        {"VST_PATH": str(bridge_root)},
        None,
    ) is None


def test_rejects_metadata_pointing_outside_requested_plugin(tmp_path: Path) -> None:
    bridge_root = tmp_path / "bridge"
    clone = tmp_path / "clone"
    other = clone / "Other.dll"
    requested = clone / "Good.dll"
    other.parent.mkdir(parents=True)
    other.write_bytes(b"other")
    requested.write_bytes(b"good")

    bridge_root.mkdir(parents=True)
    (bridge_root / "Other.dll").symlink_to(other)
    (bridge_root / "Other.so").write_bytes(b"chainloader")

    assert discover_bridge(
        requested,
        PluginType.VST2,
        {"VST_PATH": str(bridge_root)},
        None,
    ) is None


def test_rejects_ambiguous_multiple_metadata_matches(tmp_path: Path) -> None:
    bridge_root = tmp_path / "bridge"
    clone = tmp_path / "clone"
    bridge_root.mkdir(parents=True)
    requested = clone / "Good.dll"
    requested.parent.mkdir(parents=True)
    requested.write_bytes(b"good")

    for name in ("Good", "Good-copy"):
        (bridge_root / f"{name}.dll").symlink_to(requested)
        (bridge_root / f"{name}.so").write_bytes(b"chainloader")

    assert discover_bridge(
        requested,
        PluginType.VST2,
        {"VST_PATH": str(bridge_root)},
        None,
    ) is None


def test_rejects_basename_substring_match(tmp_path: Path) -> None:
    bridge_root = tmp_path / "bridge"
    clone = tmp_path / "clone"
    bridge_root.mkdir(parents=True)
    requested = clone / "nested" / "Good.dll"
    decoy = clone / "Good.dll"
    requested.parent.mkdir(parents=True)
    requested.write_bytes(b"requested")
    decoy.write_bytes(b"decoy")

    (bridge_root / "Good.dll").symlink_to(decoy)
    (bridge_root / "Good.so").write_bytes(b"chainloader")

    assert discover_bridge(
        requested,
        PluginType.VST2,
        {"VST_PATH": str(bridge_root)},
        None,
    ) is None


def test_parse_yabridgectl_status_parses_standard_output() -> None:
    status_text = "\n".join(
        [
            "VST3 location: '/tmp/.vst3/yabridge'",
            "/wine/plugins/",
            "  Good.vst3 :: VST3, legacy, 64-bit, synced",
            "/wine/plugins/",
            "  Broken.vst3 :: VST3, legacy, 64-bit, error",
        ]
    )

    parsed = parse_yabridgectl_status(status_text)

    assert parsed.bridge_roots == ((PluginType.VST3, Path("/tmp/.vst3/yabridge")),)
    assert parsed.plugins == (
        StatusPluginRecord(
            windows_path=Path("/wine/plugins/Good.vst3"),
            plugin_type=PluginType.VST3,
            sync_state=PluginSyncState.SYNCED,
            plugin_directory=Path("/wine/plugins"),
            bridge_root=Path("/tmp/.vst3/yabridge"),
        ),
        StatusPluginRecord(
            windows_path=Path("/wine/plugins/Broken.vst3"),
            plugin_type=PluginType.VST3,
            sync_state=PluginSyncState.ERROR,
            plugin_directory=Path("/wine/plugins"),
            bridge_root=Path("/tmp/.vst3/yabridge"),
        ),
    )
    assert all(not hasattr(record, "bridge_path") for record in parsed.plugins)


def test_parse_yabridgectl_status_ignores_malformed_lines() -> None:
    status_text = "\n".join(
        [
            "VST2 location: '/tmp/.vst/yabridge'",
            "not a plugin line",
            "  :: VST2, 64-bit, synced",
            "  Good.dll :: not-a-type, 64-bit, synced",
            "  Maybe.dll :: VST2, 64-bit, maybe",
        ]
    )

    parsed = parse_yabridgectl_status(status_text)

    assert parsed.bridge_roots == ((PluginType.VST2, Path("/tmp/.vst/yabridge")),)
    assert parsed.plugins == ()


def test_status_corroborates_exact_plugin_only() -> None:
    record = BridgeRecord(
        windows_path=Path("/clone/Good.vst3"),
        bridge_path=Path("/bridge/Good.vst3/Contents/x86_64-linux/Good.so"),
        plugin_type=PluginType.VST3,
    )
    status_text = "\n".join(
        [
            "VST3 location: '/bridge'",
            "/clone/",
            "  Good.vst3 :: VST3, legacy, 64-bit, synced",
            "/clone/",
            "  Broken.vst3 :: VST3, legacy, 64-bit, error",
        ]
    )

    assert status_corroborates_bridge(parse_yabridgectl_status(status_text), record) is True


def test_status_corroboration_ignores_unrelated_errors() -> None:
    record = BridgeRecord(
        windows_path=Path("/clone/Good.dll"),
        bridge_path=Path("/bridge/Good.so"),
        plugin_type=PluginType.VST2,
    )
    status_text = "\n".join(
        [
            "VST2 location: '/bridge'",
            "/clone/",
            "  Good.dll :: VST2, 64-bit, synced",
            "/clone/",
            "  Broken.dll :: VST2, 64-bit, error",
        ]
    )

    assert status_corroborates_bridge(parse_yabridgectl_status(status_text), record) is True


def test_status_corroboration_rejects_selected_plugin_error() -> None:
    record = BridgeRecord(
        windows_path=Path("/clone/Good.dll"),
        bridge_path=Path("/bridge/Good.so"),
        plugin_type=PluginType.VST2,
    )
    status_text = "\n".join(
        [
            "VST2 location: '/bridge'",
            "/clone/",
            "  Good.dll :: VST2, 64-bit, error",
            "/clone/",
            "  Broken.dll :: VST2, 64-bit, synced",
        ]
    )

    assert status_corroborates_bridge(parse_yabridgectl_status(status_text), record) is False


def test_status_plugin_record_cannot_claim_native_bridge_path() -> None:
    parsed = parse_yabridgectl_status(
        "\n".join(
            [
                "VST2 location: '/bridge'",
                "/clone/",
                "  Good.dll :: VST2, 64-bit, synced",
            ]
        )
    )

    assert parsed.plugins
    record = parsed.plugins[0]
    assert isinstance(record, StatusPluginRecord)
    assert "bridge_path" not in StatusPluginRecord.__dataclass_fields__
    assert "bridge_path" not in YabridgectlStatus.__dataclass_fields__


def test_with_suffix_so_assumption_does_not_find_managed_vst3_bridge(
    tmp_path: Path,
) -> None:
    clone = tmp_path / "clone"
    bridge_root = tmp_path / "bridge"
    windows_plugin, native_bridge = create_vst3_bridge(bridge_root, clone)

    guessed = windows_plugin.with_suffix(".so")
    assert not guessed.exists()

    record = discover_bridge(
        windows_plugin,
        PluginType.VST3,
        {"VST3_PATH": str(bridge_root)},
        None,
    )
    assert record is not None
    assert record.bridge_path == native_bridge.resolve()


def test_plugin_load_routes_through_bridge_record(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    clone = tmp_path / "clone"
    bridge_root = tmp_path / "bridge"
    windows_plugin, _native_bridge = create_vst2_bridge(bridge_root, clone)
    monkeypatch.setenv("VST_PATH", str(bridge_root))

    status_text = "\n".join(
        [
            f"VST2 location: '{bridge_root}'",
            f"{clone}/",
            "  Good.dll :: VST2, 64-bit, synced",
            f"{clone}/",
            "  Broken.dll :: VST2, 64-bit, error",
        ]
    )

    def fake_run_command(
        cmd: list[str], timeout: int = 30, env: dict[str, str] | None = None
    ) -> tuple[bool, str, str]:
        if cmd[:2] == ["yabridgectl", "status"]:
            return True, status_text, ""
        return False, "", "Command not found"

    monkeypatch.setattr("yabridge_test.tests.plugin_load.run_command", fake_run_command)

    test = PluginLoadTest(windows_plugin)
    bridge_result = test.check_yabridge_bridge()
    assert bridge_result.result.value == "pass"

    status_result = test.check_yabridgectl_status()
    assert status_result.result.value == "pass"


def test_plugin_load_uses_detect_wine_prefix(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    prefix = tmp_path / "prefix"
    dosdevices = prefix / "dosdevices"
    dosdevices.mkdir(parents=True)
    (prefix / "system.reg").write_text("[Software]\n")

    clone = prefix / "drive_c" / "plugins"
    bridge_root = tmp_path / "bridge"
    windows_plugin, _native_bridge = create_vst2_bridge(bridge_root, clone)
    monkeypatch.setenv("VST_PATH", str(bridge_root))
    monkeypatch.delenv("WINEPREFIX", raising=False)

    test = PluginLoadTest(windows_plugin)
    result = test.test_wine_prefix_access()
    assert result.result.value == "pass"
    assert str(prefix) in (result.details or "")
