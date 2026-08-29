"""Pydantic schemas for test results."""

from collections import Counter
from collections.abc import Sequence
from datetime import datetime, timezone
from enum import Enum
from typing import Any

from pydantic import BaseModel, Field


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


class TestResult(str, Enum):
    """Result of a single test."""

    PASS = "pass"
    FAIL = "fail"
    SKIP = "skip"
    ERROR = "error"


class DisplayServer(str, Enum):
    """Display server type."""

    X11 = "x11"
    WAYLAND = "wayland"
    XWAYLAND = "xwayland"


class PluginType(str, Enum):
    """Plugin format type."""

    VST2 = "vst2"
    VST3 = "vst3"
    CLAP = "clap"


class MonitorInfo(BaseModel):
    """Information about a display monitor."""

    width: int
    height: int
    position_x: int = 0
    position_y: int = 0
    scale: float = 1.0
    primary: bool = False
    name: str | None = None


class Environment(BaseModel):
    """System environment information."""

    # OS/Distribution
    distro: str = Field(description="Linux distribution name and version")
    kernel: str = Field(description="Kernel version")

    # Desktop environment
    desktop: str = Field(description="Desktop environment (GNOME, KDE, etc.)")
    desktop_version: str | None = Field(default=None, description="DE version")
    display_server: DisplayServer = Field(description="Native display session type")
    xwayland_available: bool = Field(
        default=False,
        description="Whether XWayland is available in a Wayland session",
    )
    compositor: str | None = Field(default=None, description="Window manager/compositor")

    # Wine
    wine_version: str = Field(description="Wine version string")
    wine_staging: bool = Field(default=False, description="Is Wine staging?")
    wine_patches: list[str] = Field(default_factory=list, description="Applied patches")
    wine_variant: str | None = Field(
        default=None,
        description="Wine variant (staging, tkg, ge, proton)",
    )
    wine_prefix: str | None = Field(default=None, description="Wine prefix path (local only)")
    wine_prefix_kind: str | None = Field(
        default=None,
        description="Prefix class: temp-probe, isolated, clone, production, unknown",
    )
    wine_dpi: int | None = Field(default=None, description="Wine DPI setting (from winecfg)")
    wine_digest_verified: bool | None = Field(
        default=None,
        description="Whether the Kron4ek archive digest was verified",
    )
    wine_sha256: str | None = Field(
        default=None,
        description="SHA-256 of the verified Wine archive",
    )

    # Yabridge
    yabridge_version: str = Field(description="Yabridge version")
    yabridge_commit: str | None = Field(default=None, description="Git commit hash")
    yabridge_branch: str | None = Field(default=None, description="Git branch")

    # Display
    dpi_scale: float = Field(default=1.0, description="DPI scaling factor")
    monitors: list[MonitorInfo] = Field(default_factory=list, description="Monitor configuration")

    # Hardware
    cpu: str | None = Field(default=None, description="CPU model")
    gpu: str | None = Field(default=None, description="GPU model")
    gpu_driver: str | None = Field(default=None, description="GPU driver (nvidia, amdgpu, intel)")
    ram_gb: float | None = Field(default=None, description="RAM in GB")


class PluginInfo(BaseModel):
    """Information about a tested plugin."""

    name: str = Field(description="Plugin name")
    type: PluginType = Field(description="Plugin format (vst2, vst3, clap)")
    vendor: str | None = Field(default=None, description="Plugin vendor")
    version: str | None = Field(default=None, description="Plugin version")
    path: str | None = Field(default=None, description="Path to plugin file")


class SingleTestResult(BaseModel):
    """Result of a single test."""

    name: str = Field(description="Test name")
    result: TestResult = Field(description="Test result")
    details: str | None = Field(default=None, description="Additional details")
    duration_ms: int | None = Field(default=None, description="Test duration in ms")
    error: str | None = Field(default=None, description="Error message if failed")
    measurements: dict[str, Any] | None = Field(
        default=None,
        description="Structured probe measurements for bridged coordinate tests",
    )


class ResultSummary(BaseModel):
    """Aggregated counts for a batch of test results."""

    passed: int
    failed: int
    errors: int
    skipped: int
    total: int

    @classmethod
    def from_results(cls, results: Sequence[SingleTestResult]) -> "ResultSummary":
        counts = Counter(result.result for result in results)
        return cls(
            passed=counts[TestResult.PASS],
            failed=counts[TestResult.FAIL],
            errors=counts[TestResult.ERROR],
            skipped=counts[TestResult.SKIP],
            total=len(results),
        )

    @property
    def unsuccessful(self) -> bool:
        return self.total == 0 or self.failed > 0 or self.errors > 0


class TestReport(BaseModel):
    """Complete test report for submission."""

    # Metadata
    timestamp: datetime = Field(default_factory=_utc_now)
    report_version: str = Field(default="1.0.0", description="Schema version")

    # Environment
    environment: Environment

    # DAW/Host
    host: str | None = Field(default=None, description="DAW host (ardour, carla, reaper, etc.)")
    host_version: str | None = Field(default=None, description="Host version")

    # Plugin being tested
    plugin: PluginInfo | None = Field(default=None, description="Plugin under test")

    # Test results
    tests: list[SingleTestResult] = Field(default_factory=list, description="Test results")

    # Additional context
    workarounds: list[str] = Field(default_factory=list, description="Workarounds applied")
    notes: str | None = Field(default=None, description="Additional notes")
    logs: str | None = Field(default=None, description="Relevant log output")
    screenshots: list[str] = Field(
        default_factory=list, description="Base64-encoded screenshots"
    )

    # How the data was produced (probe, suite, plugin, isolated-daw, web-manual)
    session_type: str | None = Field(default=None, description="How this report was produced")
    regression: bool | None = Field(
        default=None,
        description="Whether this used to work and now does not",
    )

    # Submission metadata
    submitter: str | None = Field(default=None, description="Submitter identifier")
    submitter_contact: str | None = Field(default=None, description="Contact info (optional)")


class SubmitResponse(BaseModel):
    """Response from submission API."""

    success: bool
    message: str
    report_id: int | None = None
    url: str | None = None
    # Draft completion fields
    completion_url: str | None = None
    completion_token: str | None = None


class MatrixCell(BaseModel):
    """Single cell in compatibility matrix."""

    status: TestResult
    count: int = 0
    last_tested: datetime | None = None


class CompatibilityMatrix(BaseModel):
    """Compatibility matrix data."""

    rows: list[str] = Field(description="Row labels (e.g., Wine versions)")
    columns: list[str] = Field(description="Column labels (e.g., DEs)")
    data: dict[str, dict[str, MatrixCell]] = Field(description="Matrix data")
    generated_at: datetime = Field(default_factory=_utc_now)
