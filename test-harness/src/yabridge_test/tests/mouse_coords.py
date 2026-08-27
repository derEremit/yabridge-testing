"""Pointer backend prerequisite check for coordinate probe scenarios."""

import subprocess
from typing import Any

from ..schemas import SingleTestResult, TestResult


def run_command(cmd: list[str], timeout: int = 10) -> tuple[bool, str]:
    """Run a command and return success status and output."""
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return result.returncode == 0, result.stdout.strip()
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError) as exc:
        return False, str(exc)


class PointerBackendSanity:
    """Prerequisite check that the XTEST pointer backend is available.

    This replaces the legacy global-pointer round trip. It may only report
    PASS or SKIP and never claims issue #409 coordinate verdicts.
    """

    def __init__(self) -> None:
        self.results: list[dict[str, Any]] = []

    def check_xtest(self) -> bool:
        """Return True when xdpyinfo confirms the XTEST extension."""
        success, output = run_command(["xdpyinfo", "-queryExtensions"])
        return success and "XTEST" in output.upper()

    def run_all(self) -> list[SingleTestResult]:
        """Run the pointer backend prerequisite check."""
        if not self.check_xtest():
            return [
                SingleTestResult(
                    name="pointer_backend_sanity",
                    result=TestResult.SKIP,
                    details="XTEST extension not available",
                )
            ]

        return [
            SingleTestResult(
                name="pointer_backend_sanity",
                result=TestResult.PASS,
                details="XTEST pointer backend available",
            )
        ]


# Deprecated compatibility alias; cannot emit coordinate verdicts.
MouseCoordinateTest = PointerBackendSanity
