"""CLI contract tests for the bridged coordinate probe."""

from __future__ import annotations

import json
from pathlib import Path

import pytest
from click.testing import CliRunner

from yabridge_test.cli import main
from yabridge_test.schemas import (
    DisplayServer,
    Environment,
    SingleTestResult,
)
from yabridge_test.schemas import (
    TestResult as HarnessTestResult,
)


class FakeProbe:
    seen: list[object] = []
    results = [
        SingleTestResult(
            name="probe_offset",
            result=HarnessTestResult.PASS,
            measurements={"x": 1},
        )
    ]

    def __init__(self, options: object | None = None) -> None:
        self.seen.append(options)

    def run_all(self) -> list[SingleTestResult]:
        return self.results


class FakePointer:
    def run_all(self) -> list[SingleTestResult]:
        return [
            SingleTestResult(
                name="pointer_backend_sanity",
                result=HarnessTestResult.PASS,
            )
        ]


def _environment(_plugin: object | None = None) -> Environment:
    return Environment(
        distro="test",
        kernel="test",
        desktop="test",
        display_server=DisplayServer.WAYLAND,
        xwayland_available=True,
        wine_version="test",
        yabridge_version="test",
    )


@pytest.fixture
def runner() -> CliRunner:
    return CliRunner()


def test_probe_exact_options_and_json_stdout(
    runner: CliRunner, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    FakeProbe.seen.clear()
    library = tmp_path / "libyabridge-clap.so"
    prefix = tmp_path / "prefix"
    monkeypatch.setattr("yabridge_test.cli.WineChildWindowTest", FakeProbe)

    result = runner.invoke(
        main,
        [
            "probe",
            "--scenario",
            "offset",
            "--no-headless",
            "--allow-pointer-warp",
            "--yabridge-lib",
            str(library),
            "--wine-prefix",
            str(prefix),
            "--samples",
            "3",
            "--tolerance",
            "4",
            "--json",
        ],
    )

    assert result.exit_code == 0
    document = json.loads(result.stdout)
    assert document["summary"] == {
        "passed": 1,
        "failed": 0,
        "errors": 0,
        "skipped": 0,
        "total": 1,
    }
    assert document["tests"][0]["name"] == "probe_offset"
    options = FakeProbe.seen[-1]
    assert options.scenario == "offset"
    assert options.headless is False
    assert options.yabridge_lib == library
    assert options.wine_prefix == prefix
    assert options.samples == 3
    assert options.tolerance == 4
    assert options.allow_pointer_warp is True


def test_no_headless_does_not_imply_pointer_approval(
    runner: CliRunner, monkeypatch: pytest.MonkeyPatch
) -> None:
    FakeProbe.seen.clear()
    monkeypatch.setattr("yabridge_test.cli.WineChildWindowTest", FakeProbe)

    result = runner.invoke(main, ["probe", "--no-headless", "--json"])

    assert result.exit_code == 0
    assert FakeProbe.seen[-1].headless is False
    assert FakeProbe.seen[-1].allow_pointer_warp is False


def test_explicit_mistyped_library_is_json_error(
    runner: CliRunner, tmp_path: Path
) -> None:
    result = runner.invoke(
        main,
        ["probe", "--yabridge-lib", str(tmp_path / "typo.so"), "--json"],
    )

    assert result.exit_code == 1
    document = json.loads(result.stdout)
    assert document["summary"]["errors"] == 8
    assert all(test["result"] == "error" for test in document["tests"])


def test_probe_started_error_exits_nonzero_and_json_remains_valid(
    runner: CliRunner, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr("yabridge_test.cli.WineChildWindowTest", FakeProbe)
    FakeProbe.results = [
        SingleTestResult(name="probe_origin", result=HarnessTestResult.ERROR)
    ]
    try:
        result = runner.invoke(main, ["probe", "--json"])
    finally:
        FakeProbe.results = [
            SingleTestResult(name="probe_offset", result=HarnessTestResult.PASS)
        ]

    assert result.exit_code == 1
    assert json.loads(result.stdout)["summary"]["errors"] == 1


def test_probe_all_skip_is_success(
    runner: CliRunner, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr("yabridge_test.cli.WineChildWindowTest", FakeProbe)
    FakeProbe.results = [
        SingleTestResult(
            name="probe_origin",
            result=HarnessTestResult.SKIP,
            details="missing prerequisite: Xvfb",
        )
    ]
    try:
        result = runner.invoke(main, ["probe", "--json"])
    finally:
        FakeProbe.results = [
            SingleTestResult(name="probe_offset", result=HarnessTestResult.PASS)
        ]

    assert result.exit_code == 0
    assert json.loads(result.stdout)["summary"]["skipped"] == 1


def test_validate_runs_pointer_sanity_and_measured_probe(
    runner: CliRunner, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr("yabridge_test.cli.PointerBackendSanity", FakePointer)
    monkeypatch.setattr("yabridge_test.cli.WineChildWindowTest", FakeProbe)

    result = runner.invoke(main, ["validate"])

    assert result.exit_code == 0
    assert "pointer_backend_sanity" in result.stdout
    assert "probe_offset" in result.stdout


def test_suite_includes_probe_without_user_plugin_and_prints_errors_and_session(
    runner: CliRunner, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr("yabridge_test.cli.collect_environment", _environment)
    monkeypatch.setattr("yabridge_test.cli.PointerBackendSanity", FakePointer)
    monkeypatch.setattr("yabridge_test.cli.WineChildWindowTest", FakeProbe)

    result = runner.invoke(main, ["suite"])

    assert result.exit_code == 0
    assert "Errors: 0" in result.stdout
    assert "Native session: wayland" in result.stdout
    assert "XWayland available: Yes" in result.stdout
