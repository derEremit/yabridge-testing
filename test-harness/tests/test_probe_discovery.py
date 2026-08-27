"""Discovery and isolated fixture tests for the bridged coordinate probe."""

from __future__ import annotations

import hashlib
import os
import subprocess
from pathlib import Path

import pytest

from yabridge_test.probe.discovery import (
    DiscoveryError,
    YabridgeIdentity,
    discover_yabridge,
)
from yabridge_test.probe.fixture import FixtureError, ProbeFixture


def _shared_library(directory: Path, name: str, version: str = "9.9.9") -> Path:
    source = directory / "version.c"
    source.write_text(
        f'__attribute__((visibility("default"))) '
        f'const char *yabridge_version(void) {{ return "{version}"; }}\n'
    )
    library = directory / name
    subprocess.run(
        ["cc", "-shared", "-fPIC", str(source), "-o", str(library)],
        check=True,
        capture_output=True,
    )
    return library


def _install(directory: Path, *, chainloader: bool = False) -> tuple[Path, Path]:
    directory.mkdir(parents=True)
    name = "libyabridge-chainloader-clap.so" if chainloader else "libyabridge-clap.so"
    library = _shared_library(directory, name)
    host = directory / "yabridge-host.exe"
    host.write_bytes(b"MZ" + b"\0" * 62)
    host.chmod(0o755)
    return library, host


def _pe64(payload: bytes = b"synthetic probe") -> bytes:
    image = bytearray(128 + len(payload))
    image[:2] = b"MZ"
    image[0x3C:0x40] = (0x40).to_bytes(4, "little")
    image[0x40:0x44] = b"PE\0\0"
    image[0x44:0x46] = (0x8664).to_bytes(2, "little")
    image[128:] = payload
    return bytes(image)


def test_explicit_library_wins_and_records_canonical_identity(tmp_path: Path) -> None:
    explicit_lib, host = _install(tmp_path / "explicit")
    _install(tmp_path / "home" / ".local" / "share" / "yabridge")

    identity = discover_yabridge(
        explicit=explicit_lib,
        environ={"HOME": str(tmp_path / "home")},
    )

    assert identity.library_path == explicit_lib.resolve()
    assert identity.host_path == host.resolve()
    assert identity.mode == "full"
    assert identity.version == "9.9.9"
    assert identity.sha256 == hashlib.sha256(explicit_lib.read_bytes()).hexdigest()


def test_environment_path_precedes_verified_staging_root(tmp_path: Path) -> None:
    env_lib, _ = _install(tmp_path / "env")
    staging_lib, _ = _install(tmp_path / "staging" / "build" / "yabridge")
    root = tmp_path / "staging"
    (root / "build").mkdir(exist_ok=True)
    (root / "build" / "component-state.env").write_text(
        "YABRIDGE_REF=main\nYABRIDGE_COMMIT=" + "a" * 40 + "\n"
    )

    identity = discover_yabridge(
        environ={
            "YABRIDGE_PROBE_LIB": str(env_lib),
            "YABRIDGE_TEST_ROOT": str(root),
            "HOME": str(tmp_path / "missing-home"),
        }
    )

    assert identity.library_path == env_lib.resolve()
    assert identity.library_path != staging_lib.resolve()


def test_staging_root_requires_verified_identity(tmp_path: Path) -> None:
    root = tmp_path / "staging"
    _install(root / "build" / "yabridge")

    with pytest.raises(DiscoveryError, match="verified staging identity"):
        discover_yabridge(
            environ={
                "YABRIDGE_TEST_ROOT": str(root),
                "HOME": str(tmp_path / "missing-home"),
            }
        )


def test_documented_user_install_is_last_discovery_location(tmp_path: Path) -> None:
    install = tmp_path / "home" / ".local" / "share" / "yabridge"
    library, _ = _install(install)

    identity = discover_yabridge(environ={"HOME": str(tmp_path / "home")})

    assert identity.library_path == library.resolve()


def test_chainloader_requires_runtime_home_and_path_layout(tmp_path: Path) -> None:
    chainloader, host = _install(tmp_path / "build", chainloader=True)
    runtime_home = tmp_path / "home"
    runtime_install = runtime_home / ".local" / "share" / "yabridge"
    full, _ = _install(runtime_install)

    identity = discover_yabridge(
        explicit=chainloader,
        environ={
            "HOME": str(runtime_home),
            "PATH": os.pathsep.join(["/usr/bin", str(chainloader.parent)]),
        },
    )

    assert identity.mode == "chainloader"
    assert identity.host_path == host.resolve()
    assert identity.runtime_library_path == full.resolve()


def test_chainloader_without_required_layout_is_rejected(tmp_path: Path) -> None:
    chainloader, _ = _install(tmp_path / "build", chainloader=True)

    with pytest.raises(DiscoveryError, match="chainloader"):
        discover_yabridge(
            explicit=chainloader,
            environ={"HOME": str(tmp_path / "empty"), "PATH": "/usr/bin"},
        )


def test_missing_or_incompatible_host_is_rejected(tmp_path: Path) -> None:
    library = _shared_library(tmp_path, "libyabridge-clap.so")
    with pytest.raises(DiscoveryError, match="host"):
        discover_yabridge(explicit=library, environ={"HOME": str(tmp_path)})

    host = tmp_path / "yabridge-host.exe"
    host.write_text("not a Windows executable")
    host.chmod(0o755)
    with pytest.raises(DiscoveryError, match="compatible host"):
        discover_yabridge(explicit=library, environ={"HOME": str(tmp_path)})


def test_fixture_is_temporary_exact_and_never_mutates_source(tmp_path: Path) -> None:
    library, host = _install(tmp_path / "build")
    windows_plugin = tmp_path / "coordprobe.clap-win"
    windows_plugin.write_bytes(_pe64())
    identity = YabridgeIdentity.from_paths(library, host)
    before = library.read_bytes()

    with ProbeFixture(identity, windows_plugin) as fixture:
        assert fixture.directory.parent != library.parent
        assert fixture.native_plugin.name == "probe.clap"
        assert fixture.native_plugin.is_symlink()
        assert fixture.native_plugin.resolve() == library.resolve()
        assert fixture.windows_plugin.name == "probe.clap-win"
        assert fixture.windows_plugin.read_bytes() == windows_plugin.read_bytes()
        assert fixture.library_sha256 == identity.sha256
        assert fixture.windows_sha256 == hashlib.sha256(windows_plugin.read_bytes()).hexdigest()
        fixture_root = fixture.directory

    assert not fixture_root.exists()
    assert library.read_bytes() == before


def test_fixture_rejects_concurrent_instances(tmp_path: Path) -> None:
    library, host = _install(tmp_path / "build")
    windows_plugin = tmp_path / "coordprobe.clap-win"
    windows_plugin.write_bytes(_pe64())
    identity = YabridgeIdentity.from_paths(library, host)

    with ProbeFixture(identity, windows_plugin):
        with pytest.raises(FixtureError, match="already active"):
            with ProbeFixture(identity, windows_plugin):
                pass


def test_fixture_config_never_enables_group_hosting(tmp_path: Path) -> None:
    library, host = _install(tmp_path / "build")
    windows_plugin = tmp_path / "coordprobe.clap-win"
    windows_plugin.write_bytes(_pe64())

    with ProbeFixture(
        YabridgeIdentity.from_paths(library, host),
        windows_plugin,
        config={"editor_coordinate_hack": "auto"},
    ) as fixture:
        assert fixture.config_path is not None
        text = fixture.config_path.read_text()
        assert "group" not in text.lower()


def test_fixture_rejects_non_x86_64_windows_probe(tmp_path: Path) -> None:
    library, host = _install(tmp_path / "build")
    windows_plugin = tmp_path / "coordprobe.clap-win"
    image = bytearray(_pe64())
    image[0x44:0x46] = (0x14C).to_bytes(2, "little")
    windows_plugin.write_bytes(image)

    with pytest.raises(FixtureError, match="x86-64 PE"):
        with ProbeFixture(YabridgeIdentity.from_paths(library, host), windows_plugin):
            pass
