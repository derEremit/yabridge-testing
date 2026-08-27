"""CLI exit status tests for centralized result semantics."""

from pathlib import Path

import pytest
from click.testing import CliRunner

from yabridge_test.cli import main
from yabridge_test.schemas import (
    DisplayServer,
    Environment,
    SingleTestResult,
    SubmitResponse,
)
from yabridge_test.schemas import (
    TestResult as HarnessTestResult,
)
from yabridge_test.submit import SubmitError
from yabridge_test.tests import PluginLoadTest, PointerBackendSanity, WineChildWindowTest


def _minimal_environment() -> Environment:
    return Environment(
        distro="test",
        kernel="test",
        desktop="test",
        display_server=DisplayServer.X11,
        wine_version="test",
        yabridge_version="test",
    )


@pytest.fixture
def runner() -> CliRunner:
    return CliRunner()


@pytest.fixture(autouse=True)
def no_live_probe(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(WineChildWindowTest, "run_all", lambda self: [])


@pytest.mark.parametrize("status", [HarnessTestResult.FAIL, HarnessTestResult.ERROR])
def test_unsuccessful_status_exits_nonzero(
    runner: CliRunner, monkeypatch: pytest.MonkeyPatch, status: HarnessTestResult
) -> None:
    monkeypatch.setattr(
        PointerBackendSanity,
        "run_all",
        lambda self: [SingleTestResult(name="probe", result=status)],
    )
    assert runner.invoke(main, ["validate"]).exit_code == 1


def test_empty_execution_exits_nonzero(runner: CliRunner, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(PointerBackendSanity, "run_all", lambda self: [])
    assert runner.invoke(main, ["validate"]).exit_code == 1


@pytest.mark.parametrize("status", [HarnessTestResult.FAIL, HarnessTestResult.ERROR])
def test_plugin_unsuccessful_status_exits_nonzero(
    runner: CliRunner,
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    status: HarnessTestResult,
) -> None:
    plugin = tmp_path / "test.vst3"
    plugin.mkdir()
    monkeypatch.setattr(PluginLoadTest, "get_plugin_info", lambda self: None)
    monkeypatch.setattr(
        PluginLoadTest,
        "run_all",
        lambda self: [SingleTestResult(name="load", result=status)],
    )
    assert runner.invoke(main, ["plugin", str(plugin)]).exit_code == 1


def test_plugin_empty_execution_exits_nonzero(
    runner: CliRunner, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    plugin = tmp_path / "test.vst3"
    plugin.mkdir()
    monkeypatch.setattr(PluginLoadTest, "get_plugin_info", lambda self: None)
    monkeypatch.setattr(PluginLoadTest, "run_all", lambda self: [])
    assert runner.invoke(main, ["plugin", str(plugin)]).exit_code == 1


@pytest.mark.parametrize("status", [HarnessTestResult.FAIL, HarnessTestResult.ERROR])
def test_suite_unsuccessful_status_exits_nonzero(
    runner: CliRunner, monkeypatch: pytest.MonkeyPatch, status: HarnessTestResult
) -> None:
    monkeypatch.setattr("yabridge_test.cli.collect_environment", _minimal_environment)
    monkeypatch.setattr(
        PointerBackendSanity,
        "run_all",
        lambda self: [SingleTestResult(name="probe", result=status)],
    )
    assert runner.invoke(main, ["suite"]).exit_code == 1


def test_suite_empty_execution_exits_nonzero(
    runner: CliRunner, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr("yabridge_test.cli.collect_environment", _minimal_environment)
    monkeypatch.setattr(PointerBackendSanity, "run_all", lambda self: [])
    assert runner.invoke(main, ["suite"]).exit_code == 1


def test_suite_failed_submit_exits_nonzero(
    runner: CliRunner, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr("yabridge_test.cli.collect_environment", _minimal_environment)
    monkeypatch.setattr(
        PointerBackendSanity,
        "run_all",
        lambda self: [SingleTestResult(name="probe", result=HarnessTestResult.PASS)],
    )

    class FakeSubmitter:
        def submit(self, report: object) -> SubmitResponse:
            return SubmitResponse(success=False, message="submission rejected")

    monkeypatch.setattr("yabridge_test.cli.ResultSubmitter", lambda **kwargs: FakeSubmitter())
    assert runner.invoke(main, ["suite", "--submit"]).exit_code == 1


def test_suite_submit_error_exits_nonzero(
    runner: CliRunner, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr("yabridge_test.cli.collect_environment", _minimal_environment)
    monkeypatch.setattr(
        PointerBackendSanity,
        "run_all",
        lambda self: [SingleTestResult(name="probe", result=HarnessTestResult.PASS)],
    )

    class FakeSubmitter:
        def submit(self, report: object) -> SubmitResponse:
            raise SubmitError("connection failed")

    monkeypatch.setattr("yabridge_test.cli.ResultSubmitter", lambda **kwargs: FakeSubmitter())
    assert runner.invoke(main, ["suite", "--submit"]).exit_code == 1
