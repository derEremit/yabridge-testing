"""Verdict engine for bridged coordinate probe samples."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from ..schemas import TestResult


@dataclass(frozen=True)
class ProbeSample:
    """One coordinate measurement sample from a probe scenario."""

    x11_origin: tuple[int, int]
    warp: tuple[int, int]
    motion_client: tuple[int, int] | None
    button_down_client: tuple[int, int] | None
    plugin_origin: tuple[int, int] | None
    plugin_screen: tuple[int, int] | None
    cursor: tuple[int, int] | None
    virtual_screen_origin: tuple[int, int] | None = None


@dataclass(frozen=True)
class AssertionResult:
    """Outcome of one coordinate assertion."""

    name: str
    result: TestResult
    expected: tuple[int, int] | None
    actual: tuple[int, int] | None
    delta: tuple[int, int] | None


@dataclass(frozen=True)
class ProbeVerdict:
    """Aggregated verdict for one probe sample."""

    result: TestResult
    classification: str | None
    assertions: tuple[AssertionResult, ...]
    measurements: dict[str, Any]


def _within_tolerance(
    actual: tuple[int, int],
    expected: tuple[int, int],
    tolerance: int,
) -> bool:
    return abs(actual[0] - expected[0]) <= tolerance and abs(actual[1] - expected[1]) <= tolerance


def evaluate_sample(sample: ProbeSample, tolerance: int) -> ProbeVerdict:
    """Evaluate one probe sample against expected bridged coordinates."""
    if tolerance < 0:
        raise ValueError("tolerance must be nonnegative")

    expected_client = (
        sample.warp[0] - sample.x11_origin[0],
        sample.warp[1] - sample.x11_origin[1],
    )

    assertions: list[AssertionResult] = []
    has_error = False
    has_fail = False
    motion_client_failed = False
    client_delta: tuple[int, int] | None = None

    required_checks: tuple[tuple[str, tuple[int, int] | None, tuple[int, int]], ...] = (
        ("motion_client", sample.motion_client, expected_client),
        ("button_down_client", sample.button_down_client, expected_client),
        ("plugin_origin", sample.plugin_origin, sample.x11_origin),
        ("plugin_screen", sample.plugin_screen, sample.warp),
        ("cursor", sample.cursor, sample.warp),
    )

    for name, actual, expected in required_checks:
        if actual is None:
            assertions.append(
                AssertionResult(
                    name=name,
                    result=TestResult.ERROR,
                    expected=expected,
                    actual=None,
                    delta=None,
                )
            )
            has_error = True
            continue

        delta = (actual[0] - expected[0], actual[1] - expected[1])
        if name == "motion_client":
            client_delta = delta

        if _within_tolerance(actual, expected, tolerance):
            assertions.append(
                AssertionResult(
                    name=name,
                    result=TestResult.PASS,
                    expected=expected,
                    actual=actual,
                    delta=delta,
                )
            )
        else:
            assertions.append(
                AssertionResult(
                    name=name,
                    result=TestResult.FAIL,
                    expected=expected,
                    actual=actual,
                    delta=delta,
                )
            )
            has_fail = True
            if name == "motion_client":
                motion_client_failed = True

    classification: str | None = None
    if has_error:
        overall = TestResult.ERROR
    elif has_fail:
        overall = TestResult.FAIL
        if (
            motion_client_failed
            and client_delta is not None
            and _within_tolerance(client_delta, sample.x11_origin, tolerance)
        ):
            classification = "issue_409_local_as_global"
        elif (
            sample.plugin_origin is not None
            and sample.cursor is not None
            and sample.plugin_screen is not None
            and _within_tolerance(
                (
                    sample.plugin_origin[0] - sample.x11_origin[0],
                    sample.plugin_origin[1] - sample.x11_origin[1],
                ),
                (-sample.x11_origin[0], -sample.x11_origin[1]),
                tolerance,
            )
            and _within_tolerance(
                (sample.cursor[0] - sample.warp[0], sample.cursor[1] - sample.warp[1]),
                (-sample.x11_origin[0], -sample.x11_origin[1]),
                tolerance,
            )
            and _within_tolerance(
                (
                    sample.plugin_screen[0] - sample.warp[0],
                    sample.plugin_screen[1] - sample.warp[1],
                ),
                (-sample.x11_origin[0], -sample.x11_origin[1]),
                tolerance,
            )
        ):
            classification = "issue_409_local_as_global"
    else:
        overall = TestResult.PASS

    measurements: dict[str, Any] = {
        "x11_origin": list(sample.x11_origin),
        "warp": list(sample.warp),
        "expected_client": list(expected_client),
        "motion_client": (
            list(sample.motion_client) if sample.motion_client is not None else None
        ),
        "button_down_client": (
            list(sample.button_down_client)
            if sample.button_down_client is not None
            else None
        ),
        "plugin_origin": (
            list(sample.plugin_origin) if sample.plugin_origin is not None else None
        ),
        "plugin_screen": (
            list(sample.plugin_screen) if sample.plugin_screen is not None else None
        ),
        "cursor": list(sample.cursor) if sample.cursor is not None else None,
        "delta": list(client_delta) if client_delta is not None else None,
        "assertions": [
            {
                "name": assertion.name,
                "result": assertion.result.value,
                "expected": list(assertion.expected) if assertion.expected is not None else None,
                "actual": list(assertion.actual) if assertion.actual is not None else None,
                "delta": list(assertion.delta) if assertion.delta is not None else None,
            }
            for assertion in assertions
        ],
    }
    if sample.virtual_screen_origin is not None:
        measurements["virtual_screen_origin"] = list(sample.virtual_screen_origin)
    if classification is not None:
        measurements["classification"] = classification

    return ProbeVerdict(
        result=overall,
        classification=classification,
        assertions=tuple(assertions),
        measurements=measurements,
    )
