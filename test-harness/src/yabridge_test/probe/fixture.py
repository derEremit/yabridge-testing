"""Process-exclusive temporary CLAP fixture for the selected yabridge build."""

from __future__ import annotations

import hashlib
import shutil
import tempfile
import threading
from collections.abc import Mapping
from pathlib import Path
from types import TracebackType

from .discovery import YabridgeIdentity


class FixtureError(RuntimeError):
    """Raised when an isolated probe fixture cannot be created safely."""


_fixture_lock = threading.Lock()


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _is_x86_64_pe(path: Path) -> bool:
    try:
        image = path.read_bytes()
    except OSError:
        return False
    if len(image) < 0x40 or image[:2] != b"MZ":
        return False
    header = int.from_bytes(image[0x3C:0x40], "little")
    return (
        header + 6 <= len(image)
        and image[header : header + 4] == b"PE\0\0"
        and int.from_bytes(image[header + 4 : header + 6], "little") == 0x8664
    )


class ProbeFixture:
    """Own a temporary native bridge symlink and adjacent Windows probe copy."""

    def __init__(
        self,
        identity: YabridgeIdentity,
        windows_plugin_source: Path,
        *,
        config: Mapping[str, str] | None = None,
    ) -> None:
        self.identity = identity
        self.windows_plugin_source = windows_plugin_source
        self.config = dict(config or {})
        self.directory = Path()
        self.native_plugin = Path()
        self.windows_plugin = Path()
        self.config_path: Path | None = None
        self.library_sha256 = ""
        self.windows_sha256 = ""
        self._temporary: tempfile.TemporaryDirectory[str] | None = None
        self._locked = False

    def __enter__(self) -> ProbeFixture:
        if not _fixture_lock.acquire(blocking=False):
            raise FixtureError("a probe fixture or runner is already active in this process")
        self._locked = True
        try:
            self._create()
        except BaseException:
            self._release()
            raise
        return self

    def _create(self) -> None:
        if not self.windows_plugin_source.is_file():
            raise FixtureError(f"Windows probe artifact is missing: {self.windows_plugin_source}")
        if self.config and any("group" in key.lower() for key in self.config):
            raise FixtureError("group hosting is forbidden for the coordinate probe")

        self._temporary = tempfile.TemporaryDirectory(prefix="yabridge-probe-")
        self.directory = Path(self._temporary.name)
        self.native_plugin = self.directory / "probe.clap"
        self.windows_plugin = self.directory / "probe.clap-win"
        self.native_plugin.symlink_to(self.identity.library_path)
        shutil.copy2(self.windows_plugin_source, self.windows_plugin)

        if self.native_plugin.resolve() != self.identity.library_path:
            raise FixtureError("native fixture does not resolve to the selected yabridge library")
        self.library_sha256 = _sha256(self.native_plugin.resolve())
        if self.library_sha256 != self.identity.sha256:
            raise FixtureError("selected yabridge library changed during fixture creation")
        if not _is_x86_64_pe(self.windows_plugin):
            raise FixtureError("Windows probe artifact is not an x86-64 PE binary")
        source_hash = _sha256(self.windows_plugin_source)
        self.windows_sha256 = _sha256(self.windows_plugin)
        if self.windows_sha256 != source_hash:
            raise FixtureError("Windows probe artifact changed during fixture copy")

        if self.config:
            self.config_path = self.directory / "yabridge.toml"
            lines = [f'{key} = "{value}"' for key, value in sorted(self.config.items())]
            text = "\n".join(lines) + "\n"
            if "group" in text.lower():
                raise FixtureError("group hosting is forbidden for the coordinate probe")
            self.config_path.write_text(text)

    def _release(self) -> None:
        if self._temporary is not None:
            self._temporary.cleanup()
            self._temporary = None
        if self._locked:
            self._locked = False
            _fixture_lock.release()

    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc: BaseException | None,
        traceback: TracebackType | None,
    ) -> None:
        self._release()
