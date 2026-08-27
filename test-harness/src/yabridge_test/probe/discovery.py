"""Deterministic discovery and identity checks for the yabridge CLAP library."""

from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path

from ..provenance import ProvenanceError, StagingIdentity

FULL_NAME = "libyabridge-clap.so"
CHAINLOADER_NAME = "libyabridge-chainloader-clap.so"
HOST_NAME = "yabridge-host.exe"
ENVIRONMENT_KEYS = ("YABRIDGE_PROBE_LIB", "YABRIDGE_LIB")


class DiscoveryError(RuntimeError):
    """Raised when no safe and complete yabridge installation can be selected."""


@dataclass(frozen=True)
class YabridgeIdentity:
    """Canonical identity of the exact bridge implementation used by a run."""

    library_path: Path
    host_path: Path
    mode: str
    version: str
    sha256: str
    runtime_library_path: Path | None = None

    @classmethod
    def from_paths(
        cls,
        library_path: Path,
        host_path: Path,
        *,
        environ: Mapping[str, str] | None = None,
    ) -> YabridgeIdentity:
        """Validate explicit paths and construct a measured identity."""
        return _identity_for(library_path, environ or os.environ, expected_host=host_path)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _is_x86_64_elf(path: Path) -> bool:
    try:
        header = path.read_bytes()[:20]
    except OSError:
        return False
    if len(header) < 20 or header[:4] != b"\x7fELF":
        return False
    machine = (
        int.from_bytes(header[18:20], "little")
        if header[5] == 1
        else int.from_bytes(header[18:20], "big")
    )
    return header[4] == 2 and machine == 62


def _compatible_host(path: Path) -> bool:
    if not path.is_file() or not os.access(path, os.X_OK):
        return False
    try:
        signature = path.read_bytes()[:2]
    except OSError:
        return False
    if signature == b"MZ":
        return True
    return signature == b"#!" and path.with_name(path.name + ".so").is_file()


def _read_version_safely(path: Path) -> str:
    script = (
        "import ctypes,json,sys\n"
        "lib=ctypes.CDLL(sys.argv[1])\n"
        "fn=lib.yabridge_version\n"
        "fn.argtypes=[]\n"
        "fn.restype=ctypes.c_char_p\n"
        "value=fn()\n"
        "if value is None: raise RuntimeError('null version')\n"
        "print(json.dumps(value.decode('utf-8','strict')))\n"
    )
    try:
        completed = subprocess.run(
            [sys.executable, "-I", "-c", script, str(path)],
            check=True,
            capture_output=True,
            text=True,
            timeout=3,
        )
        value = json.loads(completed.stdout)
    except (OSError, subprocess.SubprocessError, json.JSONDecodeError) as exc:
        raise DiscoveryError(f"could not safely call yabridge_version() in {path}") from exc
    if not isinstance(value, str) or not value:
        raise DiscoveryError(f"yabridge_version() returned an invalid value in {path}")
    return value


def _runtime_chainloader_library(environ: Mapping[str, str]) -> Path | None:
    home = environ.get("HOME")
    if not home:
        return None
    candidate = Path(home) / ".local" / "share" / "yabridge" / FULL_NAME
    return candidate.resolve() if candidate.is_file() else None


def _identity_for(
    raw_library: Path,
    environ: Mapping[str, str],
    *,
    expected_host: Path | None = None,
) -> YabridgeIdentity:
    try:
        library = raw_library.expanduser().resolve(strict=True)
    except OSError as exc:
        raise DiscoveryError(f"yabridge library does not exist: {raw_library}") from exc
    if library.name not in {FULL_NAME, CHAINLOADER_NAME}:
        raise DiscoveryError(f"unsupported yabridge CLAP library name: {library.name}")
    if not _is_x86_64_elf(library):
        raise DiscoveryError(f"yabridge library is not an x86-64 ELF shared library: {library}")

    host = (expected_host or library.with_name(HOST_NAME)).expanduser()
    try:
        host = host.resolve(strict=True)
    except OSError as exc:
        raise DiscoveryError(f"required adjacent yabridge host is missing: {host}") from exc
    if host.parent != library.parent or not _compatible_host(host):
        raise DiscoveryError(f"required adjacent compatible host executable is invalid: {host}")

    mode = "chainloader" if library.name == CHAINLOADER_NAME else "full"
    runtime_library: Path | None = None
    version_source = library
    if mode == "chainloader":
        runtime_library = _runtime_chainloader_library(environ)
        path_entries = {
            Path(entry).expanduser().resolve()
            for entry in environ.get("PATH", "").split(os.pathsep)
            if entry
        }
        if (
            runtime_library is None
            or not _is_x86_64_elf(runtime_library)
            or library.parent not in path_entries
        ):
            raise DiscoveryError(
                "chainloader requires HOME/.local/share/yabridge/libyabridge-clap.so "
                "and its host directory on PATH"
            )
        version_source = runtime_library

    return YabridgeIdentity(
        library_path=library,
        host_path=host,
        mode=mode,
        version=_read_version_safely(version_source),
        sha256=_sha256(library),
        runtime_library_path=runtime_library,
    )


def _staging_candidate(root: Path) -> Path:
    try:
        identity = StagingIdentity.load(root)
    except ProvenanceError as exc:
        raise DiscoveryError(f"invalid verified staging identity: {exc}") from exc
    if identity is None:
        raise DiscoveryError(f"verified staging identity is required for {root}")
    return root / "build" / "yabridge" / FULL_NAME


def discover_yabridge(
    explicit: Path | str | None = None,
    *,
    environ: Mapping[str, str] | None = None,
) -> YabridgeIdentity:
    """Discover yabridge in explicit, verified staging, then user-install order."""
    env = dict(os.environ if environ is None else environ)
    if explicit is not None:
        return _identity_for(Path(explicit), env)

    for key in ENVIRONMENT_KEYS:
        value = env.get(key)
        if value:
            return _identity_for(Path(value), env)

    staging_root = env.get("YABRIDGE_TEST_ROOT")
    if staging_root:
        return _identity_for(_staging_candidate(Path(staging_root)), env)

    home = env.get("HOME")
    if home:
        install = Path(home) / ".local" / "share" / "yabridge"
        full = install / FULL_NAME
        if full.is_file():
            return _identity_for(full, env)
        chainloader = install / CHAINLOADER_NAME
        if chainloader.is_file():
            return _identity_for(chainloader, env)

    raise DiscoveryError(
        "no yabridge CLAP library found; use --yabridge-lib or YABRIDGE_PROBE_LIB"
    )
