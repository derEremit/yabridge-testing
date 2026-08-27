"""Shared pytest configuration for harness test selection."""

from __future__ import annotations

import pytest

PURE_MARKER_EXPRESSION = "not native_probe and not wine_probe and not live_probe"
NATIVE_PROBE_MARKER_EXPRESSION = "native_probe"
WINE_PROBE_MARKER_EXPRESSION = "wine_probe"
LIVE_PROBE_MARKER_EXPRESSION = "live_probe"


def pytest_collection_finish(session: pytest.Session) -> None:
    if not session.items:
        raise pytest.UsageError("no harness tests collected")
