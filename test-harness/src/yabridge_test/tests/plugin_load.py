"""Plugin loading tests for yabridge."""

import os
import subprocess
import time
from collections.abc import Mapping
from pathlib import Path

from ..bridge_discovery import (
    BridgeRecord,
    discover_bridge,
    parse_yabridgectl_status,
    status_corroborates_bridge,
)
from ..environment import detect_wine_prefix
from ..provenance import StagingIdentity, resolve_test_root
from ..schemas import PluginInfo, PluginType, SingleTestResult, TestResult


def run_command(
    cmd: list[str], timeout: int = 30, env: dict[str, str] | None = None
) -> tuple[bool, str, str]:
    """Run a command and return success, stdout, stderr."""
    full_env = os.environ.copy()
    if env:
        full_env.update(env)

    try:
        result = subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout, env=full_env
        )
        return result.returncode == 0, result.stdout, result.stderr
    except subprocess.TimeoutExpired:
        return False, "", "Command timed out"
    except FileNotFoundError:
        return False, "", "Command not found"
    except OSError as e:
        return False, "", str(e)


class PluginLoadTest:
    """Tests for plugin loading via yabridge."""

    def __init__(
        self,
        plugin_path: str | Path,
        environ: Mapping[str, str] | None = None,
        staging_identity: StagingIdentity | None = None,
    ) -> None:
        self.plugin_path = Path(plugin_path)
        self.environ = dict(environ if environ is not None else os.environ)
        self.staging_identity = staging_identity
        self.plugin_info: PluginInfo | None = None
        self._bridge_record: BridgeRecord | None = None
        self._bridge_record_resolved = False
        self._detect_plugin_info()

    def _detect_plugin_info(self) -> None:
        """Detect plugin information from path."""
        path = self.plugin_path
        name = path.stem

        # Detect type from extension
        suffix = path.suffix.lower()
        if suffix == ".vst3" or path.is_dir() and (path / "Contents").exists():
            plugin_type = PluginType.VST3
        elif suffix == ".dll":
            plugin_type = PluginType.VST2
        elif suffix == ".clap":
            plugin_type = PluginType.CLAP
        else:
            # Check if it's a VST3 bundle
            if path.is_dir():
                plugin_type = PluginType.VST3
            else:
                plugin_type = PluginType.VST2

        self.plugin_info = PluginInfo(
            name=name,
            type=plugin_type,
            path=str(path.absolute()),
        )

    def _resolve_staging_identity(self) -> StagingIdentity | None:
        if self.staging_identity is not None:
            return self.staging_identity
        test_root = resolve_test_root(self.environ)
        if test_root is None:
            return None
        return StagingIdentity.load(test_root)

    def _resolve_bridge_record(self) -> BridgeRecord | None:
        if not self._bridge_record_resolved:
            if self.plugin_info:
                self._bridge_record = discover_bridge(
                    self.plugin_path,
                    self.plugin_info.type,
                    self.environ,
                    self._resolve_staging_identity(),
                )
            else:
                self._bridge_record = None
            self._bridge_record_resolved = True
        return self._bridge_record

    def check_plugin_exists(self) -> SingleTestResult:
        """Check if plugin file/directory exists."""
        if self.plugin_path.exists():
            return SingleTestResult(
                name="plugin_exists",
                result=TestResult.PASS,
                details=f"Plugin found at {self.plugin_path}",
            )
        else:
            return SingleTestResult(
                name="plugin_exists",
                result=TestResult.FAIL,
                details=f"Plugin not found at {self.plugin_path}",
            )

    def check_yabridge_bridge(self) -> SingleTestResult:
        """Check if yabridge bridge file exists for the plugin."""
        if not self.plugin_info:
            return SingleTestResult(
                name="yabridge_bridge",
                result=TestResult.SKIP,
                details="Plugin info not available",
            )

        bridge = self._resolve_bridge_record()
        if bridge is not None:
            return SingleTestResult(
                name="yabridge_bridge",
                result=TestResult.PASS,
                details=f"Bridge found at {bridge.bridge_path}",
            )

        return SingleTestResult(
            name="yabridge_bridge",
            result=TestResult.FAIL,
            details="No yabridge bridge found. Run 'yabridgectl sync' first.",
        )

    def check_yabridgectl_status(self) -> SingleTestResult:
        """Check yabridgectl status for this plugin."""
        bridge = self._resolve_bridge_record()
        if bridge is None:
            return SingleTestResult(
                name="yabridgectl_status",
                result=TestResult.FAIL,
                details="Plugin bridge could not be resolved",
            )

        success, stdout, stderr = run_command(["yabridgectl", "status"], env=self.environ)

        if not success:
            return SingleTestResult(
                name="yabridgectl_status",
                result=TestResult.ERROR,
                details=f"yabridgectl failed: {stderr}",
            )

        if status_corroborates_bridge(parse_yabridgectl_status(stdout), bridge):
            return SingleTestResult(
                name="yabridgectl_status",
                result=TestResult.PASS,
                details="Plugin registered with yabridge",
            )

        return SingleTestResult(
            name="yabridgectl_status",
            result=TestResult.FAIL,
            details="Plugin not found in yabridgectl status",
        )

    def test_plugin_scan_carla(self) -> SingleTestResult:
        """Test plugin scanning with Carla (if available)."""
        # Check if carla-discovery is available
        success, _, _ = run_command(["which", "carla-discovery-native"])
        if not success:
            return SingleTestResult(
                name="plugin_scan_carla",
                result=TestResult.SKIP,
                details="Carla not installed",
            )

        if not self.plugin_info:
            return SingleTestResult(
                name="plugin_scan_carla",
                result=TestResult.SKIP,
                details="Plugin info not available",
            )

        # Determine plugin type for carla
        if self.plugin_info.type == PluginType.VST3:
            plugin_type_arg = "VST3"
        elif self.plugin_info.type == PluginType.VST2:
            plugin_type_arg = "VST2"
        else:
            return SingleTestResult(
                name="plugin_scan_carla",
                result=TestResult.SKIP,
                details=f"Plugin type {self.plugin_info.type} not supported by test",
            )

        bridge = self._resolve_bridge_record()
        if bridge is None:
            return SingleTestResult(
                name="plugin_scan_carla",
                result=TestResult.SKIP,
                details="Bridge file not found",
            )

        start_time = time.time()
        success, stdout, stderr = run_command(
            ["carla-discovery-native", plugin_type_arg, str(bridge.bridge_path)],
            timeout=60,
        )
        duration_ms = int((time.time() - start_time) * 1000)

        if success and stdout:
            return SingleTestResult(
                name="plugin_scan_carla",
                result=TestResult.PASS,
                details="Plugin scanned successfully",
                duration_ms=duration_ms,
            )
        else:
            return SingleTestResult(
                name="plugin_scan_carla",
                result=TestResult.FAIL,
                details=f"Scan failed: {stderr[:200] if stderr else 'Unknown error'}",
                duration_ms=duration_ms,
            )

    def test_wine_prefix_access(self) -> SingleTestResult:
        """Test that Wine prefix is accessible."""
        wine_prefix = detect_wine_prefix(self.plugin_path)

        if not Path(wine_prefix).exists():
            return SingleTestResult(
                name="wine_prefix_access",
                result=TestResult.FAIL,
                details=f"Wine prefix not found: {wine_prefix}",
            )

        # Check if we can access system.reg
        system_reg = Path(wine_prefix) / "system.reg"
        if system_reg.exists():
            return SingleTestResult(
                name="wine_prefix_access",
                result=TestResult.PASS,
                details=f"Wine prefix accessible: {wine_prefix}",
            )
        else:
            return SingleTestResult(
                name="wine_prefix_access",
                result=TestResult.FAIL,
                details="Wine prefix exists but may not be initialized",
            )

    def run_all(self) -> list[SingleTestResult]:
        """Run all plugin tests."""
        return [
            self.check_plugin_exists(),
            self.check_yabridge_bridge(),
            self.check_yabridgectl_status(),
            self.test_wine_prefix_access(),
            self.test_plugin_scan_carla(),
        ]

    def get_plugin_info(self) -> PluginInfo | None:
        """Get detected plugin information."""
        return self.plugin_info
