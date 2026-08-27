"""Unit tests for the coordinate probe verdict engine."""

from dataclasses import fields

from yabridge_test.probe.evaluator import ProbeSample, evaluate_sample
from yabridge_test.schemas import TestResult as HarnessTestResult


def test_local_as_global_trace_is_classified() -> None:
    sample = ProbeSample(
        x11_origin=(317, 211),
        warp=(517, 361),
        motion_client=(517, 361),
        button_down_client=(517, 361),
        plugin_origin=(317, 211),
        plugin_screen=(517, 361),
        cursor=(517, 361),
    )
    verdict = evaluate_sample(sample, tolerance=2)
    assert verdict.result is HarnessTestResult.FAIL
    assert verdict.classification == "issue_409_local_as_global"


def test_correct_coordinates_pass() -> None:
    sample = ProbeSample(
        x11_origin=(317, 211),
        warp=(517, 361),
        motion_client=(200, 150),
        button_down_client=(200, 150),
        plugin_origin=(317, 211),
        plugin_screen=(517, 361),
        cursor=(517, 361),
    )
    verdict = evaluate_sample(sample, tolerance=2)
    assert verdict.result is HarnessTestResult.PASS
    assert verdict.classification is None


def test_missing_required_measurements_are_error() -> None:
    sample = ProbeSample(
        x11_origin=(317, 211),
        warp=(517, 361),
        motion_client=None,
        button_down_client=(200, 150),
        plugin_origin=(317, 211),
        plugin_screen=(517, 361),
        cursor=(517, 361),
    )
    verdict = evaluate_sample(sample, tolerance=2)
    assert verdict.result is HarnessTestResult.ERROR


def test_mismatch_without_issue_409_signature_fails_without_classification() -> None:
    sample = ProbeSample(
        x11_origin=(317, 211),
        warp=(517, 361),
        motion_client=(210, 160),
        button_down_client=(200, 150),
        plugin_origin=(317, 211),
        plugin_screen=(517, 361),
        cursor=(517, 361),
    )
    verdict = evaluate_sample(sample, tolerance=2)
    assert verdict.result is HarnessTestResult.FAIL
    assert verdict.classification is None


def test_button_client_is_evaluated_when_present() -> None:
    sample = ProbeSample(
        x11_origin=(100, 50),
        warp=(300, 250),
        motion_client=(200, 200),
        button_down_client=(200, 200),
        plugin_origin=(100, 50),
        plugin_screen=(300, 250),
        cursor=(300, 250),
    )
    verdict = evaluate_sample(sample, tolerance=2)
    assert verdict.result is HarnessTestResult.PASS


def test_measurements_preserve_raw_coordinates_and_assertions() -> None:
    sample = ProbeSample(
        x11_origin=(317, 211),
        warp=(517, 361),
        motion_client=(517, 361),
        button_down_client=(517, 361),
        plugin_origin=(317, 211),
        plugin_screen=(517, 361),
        cursor=(517, 361),
    )
    verdict = evaluate_sample(sample, tolerance=2)
    assert verdict.measurements["x11_origin"] == [317, 211]
    assert verdict.measurements["warp"] == [517, 361]
    assert verdict.measurements["motion_client"] == [517, 361]
    assert "assertions" in verdict.measurements
    assert verdict.measurements["delta"] == [317, 211]


def test_issue_409_requires_win_client_failure() -> None:
    sample = ProbeSample(
        x11_origin=(0, 0),
        warp=(100, 100),
        motion_client=(100, 100),
        button_down_client=(100, 100),
        plugin_origin=(0, 0),
        plugin_screen=(100, 100),
        cursor=(50, 50),
    )
    verdict = evaluate_sample(sample, tolerance=2)
    assert verdict.result is HarnessTestResult.FAIL
    assert verdict.classification is None


def test_tolerance_does_not_hide_missing_measurements() -> None:
    sample = ProbeSample(
        x11_origin=(317, 211),
        warp=(517, 361),
        motion_client=None,
        button_down_client=None,
        plugin_origin=None,
        plugin_screen=None,
        cursor=None,
    )
    verdict = evaluate_sample(sample, tolerance=1000)
    assert verdict.result is HarnessTestResult.ERROR


def test_motion_button_and_plugin_screen_are_independent_assertions() -> None:
    sample = ProbeSample(
        x11_origin=(100, 50),
        warp=(141, 79),
        motion_client=(41, 29),
        button_down_client=(41, 29),
        plugin_origin=(100, 50),
        plugin_screen=(141, 79),
        cursor=(141, 79),
        virtual_screen_origin=(-1920, 0),
    )

    verdict = evaluate_sample(sample, tolerance=2)

    assert verdict.result is HarnessTestResult.PASS
    assert [assertion.name for assertion in verdict.assertions] == [
        "motion_client",
        "button_down_client",
        "plugin_origin",
        "plugin_screen",
        "cursor",
    ]
    assert verdict.measurements["motion_client"] == [41, 29]
    assert verdict.measurements["button_down_client"] == [41, 29]
    assert verdict.measurements["plugin_screen"] == [141, 79]


def test_direct_plugin_screen_mismatch_fails_even_when_clients_pass() -> None:
    sample = ProbeSample(
        x11_origin=(100, 50),
        warp=(141, 79),
        motion_client=(41, 29),
        button_down_client=(41, 29),
        plugin_origin=(100, 50),
        plugin_screen=(41, 29),
        cursor=(141, 79),
    )

    verdict = evaluate_sample(sample, tolerance=2)

    assert verdict.result is HarnessTestResult.FAIL
    screen = next(
        assertion for assertion in verdict.assertions if assertion.name == "plugin_screen"
    )
    assert screen.actual == (41, 29)


def test_probe_sample_has_no_compatibility_coordinate_aliases() -> None:
    names = {field.name for field in fields(ProbeSample)}

    assert "win_client" not in names
    assert "win_origin" not in names
    assert "button_client" not in names


def test_cursor_cannot_substitute_for_missing_direct_plugin_screen() -> None:
    sample = ProbeSample(
        x11_origin=(100, 50),
        warp=(141, 79),
        motion_client=(41, 29),
        button_down_client=(41, 29),
        plugin_origin=(100, 50),
        plugin_screen=None,
        cursor=(141, 79),
        virtual_screen_origin=(0, 0),
    )

    verdict = evaluate_sample(sample, tolerance=2)

    assert verdict.result is HarnessTestResult.ERROR
    plugin_screen = next(
        assertion for assertion in verdict.assertions if assertion.name == "plugin_screen"
    )
    assert plugin_screen.actual is None
