"""Artifact and reproducibility checks for the Windows coordinate probe."""

from __future__ import annotations

import configparser
import hashlib
import shutil
import struct
import subprocess
from pathlib import Path

import pytest

CLAP_REVISION = "094bb76c85366a13cc6c49292226d8608d6ae50c"
REPO_ROOT = Path(__file__).resolve().parents[2]
PROBE_ROOT = REPO_ROOT / "probe"
CROSS_FILE = PROBE_ROOT / "cross" / "mingw-w64-x86_64.ini"
CLAP_WRAP = PROBE_ROOT / "subprojects" / "clap.wrap"


def _require_build_tools() -> None:
    for executable in ("meson", "x86_64-w64-mingw32-gcc"):
        if shutil.which(executable) is None:
            pytest.skip(f"missing prerequisite: {executable}")


def _build(build_dir: Path) -> tuple[Path, Path]:
    subprocess.run(
        [
            "meson",
            "setup",
            "--cross-file",
            str(CROSS_FILE),
            str(build_dir),
            str(PROBE_ROOT),
        ],
        cwd=REPO_ROOT,
        check=True,
        timeout=120,
    )
    subprocess.run(
        ["meson", "compile", "-C", str(build_dir)],
        cwd=REPO_ROOT,
        check=True,
        timeout=120,
    )
    return build_dir / "coordprobe.clap-win", build_dir / "coordprobe-selftest.exe"


def _pe_fields(path: Path) -> tuple[int, int]:
    data = path.read_bytes()
    assert data[:2] == b"MZ"
    pe_offset = struct.unpack_from("<I", data, 0x3C)[0]
    assert data[pe_offset : pe_offset + 4] == b"PE\0\0"
    machine, _sections, timestamp = struct.unpack_from("<HHI", data, pe_offset + 4)
    return machine, timestamp


def test_clap_wrap_has_exact_immutable_revision() -> None:
    """Changing or floating the source pin must fail without build prerequisites."""
    parser = configparser.ConfigParser(interpolation=None)
    parser.read(CLAP_WRAP)
    assert parser["wrap-git"]["revision"] == CLAP_REVISION


@pytest.mark.native_probe
def test_probe_build_is_pinned_x86_64_and_reproducible(tmp_path: Path) -> None:
    """A timestamp, wrong target, or path leak must change/fail the artifact."""
    _require_build_tools()

    first_plugin, first_host = _build(tmp_path / "build-one")
    clap_checkout = PROBE_ROOT / "subprojects" / "clap"
    revision = subprocess.run(
        ["git", "-C", str(clap_checkout), "rev-parse", "HEAD"],
        check=True,
        capture_output=True,
        text=True,
        timeout=10,
    ).stdout.strip()
    assert revision == CLAP_REVISION

    first_bytes = first_plugin.read_bytes()
    first_host_bytes = first_host.read_bytes()
    assert _pe_fields(first_plugin) == (0x8664, 0)
    assert _pe_fields(first_host) == (0x8664, 0)
    assert str(REPO_ROOT).encode() not in first_bytes
    assert str(REPO_ROOT).encode() not in first_host_bytes

    second_plugin, second_host = _build(tmp_path / "build-two")
    assert hashlib.sha256(first_bytes).digest() == hashlib.sha256(
        second_plugin.read_bytes()
    ).digest()
    assert hashlib.sha256(first_host_bytes).digest() == hashlib.sha256(
        second_host.read_bytes()
    ).digest()
