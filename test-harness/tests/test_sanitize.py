"""Home paths and operator identifiers must not survive the POST payload."""

from __future__ import annotations

from pathlib import Path

import pytest

# Schema classes named Test* must not be bound at module scope: pytest
# tries to collect them and filterwarnings=error turns that into an error.
from yabridge_test import schemas
from yabridge_test.sanitize import classify_wine_prefix_kind, payload_for_submit
from yabridge_test.schemas import (
    DisplayServer,
    Environment,
    PluginInfo,
    PluginType,
    SingleTestResult,
)
from yabridge_test.submit import ResultSubmitter

HOME = "/home/operator/projects/yabridge-staging"


def _environment(**overrides: object) -> Environment:
    values: dict[str, object] = {
        "distro": "Arch Linux",
        "kernel": "6.8.0",
        "desktop": "KDE Plasma",
        "display_server": DisplayServer.WAYLAND,
        "wine_version": "wine-11.8 (Staging)",
        "wine_prefix": f"{HOME}/prefix-copy",
        "yabridge_version": "5.1.1",
        "yabridge_commit": "48ea9749b682c48875366134a42073d6b3d0a8c4",
    }
    values.update(overrides)
    return Environment(**values)  # type: ignore[arg-type]


def _report(**overrides: object) -> schemas.TestReport:
    values: dict[str, object] = {
        "environment": _environment(),
        "host": "bitwig-studio",
        "plugin": PluginInfo(
            name="Addictive Keys",
            type=PluginType.VST3,
            path=f"{HOME}/prefix-copy/drive_c/Program Files/Common Files/VST3/Addictive Keys.vst3",
        ),
        "tests": [
            SingleTestResult(
                name="probe_offset",
                result=schemas.TestResult.PASS,
                details=f"Wine prefix accessible: {HOME}/prefix-copy",
                measurements={
                    "yabridge": {
                        "library": f"{HOME}/build/yabridge/libyabridge-clap.so",
                        "mode": "chainloader",
                        "version": "5.1.1",
                        "sha256": "a" * 64,
                    },
                    "yabridge_log_tail": f"loading {HOME}/prefix-copy/drive_c/plugin.dll",
                    "classification": "issue_409_local_as_global",
                },
            )
        ],
        "notes": f"Session on {HOME} contact me@example.com MAC 02:00:5e:00:53:01 ComputerId=ABC",
        "logs": f"opened {HOME}/.wine/drive_c",
        "submitter_contact": "me@example.com",
        "session_type": "isolated-daw",
    }
    values.update(overrides)
    return schemas.TestReport(**values)  # type: ignore[arg-type]


def test_payload_strips_home_paths_and_operator_identifiers() -> None:
    payload = payload_for_submit(_report())
    dumped = str(payload)

    assert HOME not in dumped
    assert "/home/" not in dumped
    assert "me@example.com" not in dumped
    assert "02:00:5e:00:53:01" not in dumped
    assert "ComputerId=ABC" not in dumped
    assert "wine_prefix" not in payload["environment"]
    assert payload["environment"]["wine_prefix_kind"] in {
        "clone",
        "unknown",
        "production",
        "isolated",
        "temp-probe",
    }
    assert "path" not in (payload.get("plugin") or {})
    assert payload["tests"][0]["details"] == "Wine prefix accessible: [path]"
    yabridge = payload["tests"][0]["measurements"]["yabridge"]
    assert "library" not in yabridge
    assert yabridge["sha256"] == "a" * 64
    assert yabridge["mode"] == "chainloader"
    assert "yabridge_log_tail" not in payload["tests"][0]["measurements"]
    assert payload["session_type"] == "isolated-daw"
    assert payload["report_version"] == "1.2.0"
    assert "submitter_contact" not in payload


def test_payload_classifies_isolated_and_clone_prefixes(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    isolated = tmp_path / "prefix"
    clone = tmp_path / "prefix-copy"
    isolated.mkdir()
    clone.mkdir()
    monkeypatch.setenv("YABRIDGE_TEST_ROOT", str(tmp_path))

    isolated_payload = payload_for_submit(
        _report(environment=_environment(wine_prefix=str(isolated)))
    )
    clone_payload = payload_for_submit(
        _report(environment=_environment(wine_prefix=str(clone)))
    )

    assert isolated_payload["environment"]["wine_prefix_kind"] == "isolated"
    assert clone_payload["environment"]["wine_prefix_kind"] == "clone"
    assert "wine_prefix" not in isolated_payload["environment"]
    assert str(tmp_path) not in str(isolated_payload)


def test_temp_probe_prefix_kind() -> None:
    assert (
        classify_wine_prefix_kind("/tmp/yabridge-probe-prefix-abc123") == "temp-probe"
    )


def test_submitter_posts_sanitized_json(monkeypatch: pytest.MonkeyPatch) -> None:
    captured: dict[str, object] = {}

    class FakeResponse:
        status_code = 201

        def json(self) -> dict[str, object]:
            return {
                "draft_id": 7,
                "completion_url": "https://example.test/complete/token",
                "completion_token": "token",
            }

        @property
        def text(self) -> str:
            return ""

    class FakeClient:
        def __init__(self, timeout: object) -> None:
            pass

        def __enter__(self) -> FakeClient:
            return self

        def __exit__(self, *args: object) -> None:
            return None

        def post(self, url: str, json: dict[str, object], headers: dict[str, str]) -> FakeResponse:
            captured["url"] = url
            captured["json"] = json
            return FakeResponse()

    monkeypatch.setattr("yabridge_test.submit.httpx.Client", FakeClient)

    response = ResultSubmitter(api_url="https://example.test").submit(_report())

    assert response.success
    assert captured["url"] == "https://example.test/api/v1/drafts"
    body = captured["json"]
    assert isinstance(body, dict)
    assert HOME not in str(body)
    assert "/home/" not in str(body)
    assert "/api/v1/results" not in str(captured["url"])


def test_oversized_measurements_are_trimmed_to_the_server_budget() -> None:
    from yabridge_test.sanitize import _measurement_nodes

    # Mirror the real failure shapes: raw_events is a dict of per-cycle
    # lists, samples is a single-entry list holding one huge dict.
    events = [{"seq": i, "type": "mouse", "x": i, "y": i} for i in range(200)]
    raw_events = {"cycle_1": list(events), "cycle_2": list(events)}
    samples = [{"cycle": 1, "events": list(events), "xtest": {"press": True}}]
    report = _report(
        tests=[
            SingleTestResult(
                name="probe_nested",
                result=schemas.TestResult.FAIL,
                details="missing_plugin_input_evidence",
                measurements={
                    "classification": "missing_plugin_input_evidence",
                    "x11_origin": [375, 322],
                    "assertions": [
                        {"name": "plugin_input_delivery", "result": "fail"}
                    ],
                    "raw_events": raw_events,
                    "samples": samples,
                },
            )
        ]
    )

    payload = payload_for_submit(report)
    measurements = payload["tests"][0]["measurements"]

    assert _measurement_nodes(measurements) <= 2048
    # Scalars and assertions survive untouched; only bulky lists shrink,
    # keeping the oldest entries and recording what was cut.
    assert measurements["classification"] == "missing_plugin_input_evidence"
    assert measurements["x11_origin"] == [375, 322]
    assert measurements["assertions"] == [
        {"name": "plugin_input_delivery", "result": "fail"}
    ]
    # Oldest entries survive, wherever the bulk lived in the tree.
    assert measurements["raw_events"]["cycle_1"][0]["seq"] == 0
    dropped = measurements.get("raw_events_dropped", 0) + measurements.get(
        "samples_dropped", 0
    )
    assert dropped > 0


def test_measurements_within_budget_are_untouched() -> None:
    payload = payload_for_submit(_report())
    measurements = payload["tests"][0]["measurements"]
    assert "classification" in measurements
    assert not any(key.endswith("_dropped") for key in measurements)
