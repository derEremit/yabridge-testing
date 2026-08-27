"""Unit tests for the XTEST pointer backend prerequisite check."""

from unittest.mock import patch

from yabridge_test.schemas import TestResult as HarnessTestResult
from yabridge_test.tests.mouse_coords import PointerBackendSanity


def test_xtest_available_passes() -> None:
    sanity = PointerBackendSanity()
    with patch(
        "yabridge_test.tests.mouse_coords.run_command",
        return_value=(True, "XTEST\nXINERAMA"),
    ):
        assert sanity.check_xtest() is True
        results = sanity.run_all()
    assert len(results) == 1
    assert results[0].result is HarnessTestResult.PASS


def test_xtest_missing_skips_even_when_xdotool_exists() -> None:
    sanity = PointerBackendSanity()
    with patch(
        "yabridge_test.tests.mouse_coords.run_command",
        side_effect=[
            (True, "XINERAMA\nRENDER"),
            (True, "/usr/bin/xdotool"),
        ],
    ):
        assert sanity.check_xtest() is False
        results = sanity.run_all()
    assert len(results) == 1
    assert results[0].result is HarnessTestResult.SKIP


def test_xdpyinfo_failure_skips() -> None:
    sanity = PointerBackendSanity()
    with patch(
        "yabridge_test.tests.mouse_coords.run_command",
        return_value=(False, "xdpyinfo: unable to open display"),
    ):
        assert sanity.check_xtest() is False
        results = sanity.run_all()
    assert len(results) == 1
    assert results[0].result is HarnessTestResult.SKIP
