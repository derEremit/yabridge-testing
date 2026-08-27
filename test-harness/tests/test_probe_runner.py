"""Golden trace tests for bridged scenario orchestration."""

from __future__ import annotations

import json
import os
import threading
import time
from collections import deque
from pathlib import Path
from typing import Any

import pytest

from yabridge_test.probe.protocol import ProbeMessage
from yabridge_test.probe.runner import (
    BaselineState,
    ProbeOptions,
    ScenarioExecutor,
    WineChildWindowTest,
    scenario_spec,
)
from yabridge_test.probe.xserver import DisplayAllocator, XServer, XServerError
from yabridge_test.schemas import SingleTestResult
from yabridge_test.schemas import TestResult as HarnessTestResult

WM_MOUSEMOVE = 0x0200
WM_LBUTTONDOWN = 0x0201
WM_LBUTTONUP = 0x0202


def _message(sequence: int, kind: str, **fields: Any) -> ProbeMessage:
    return ProbeMessage(version=1, seq=sequence, type=kind, fields=fields)


class FakeTransport:
    def __init__(
        self,
        events: list[ProbeMessage | BaseException],
        *,
        echo_empty_marks: bool = False,
    ) -> None:
        self.events = deque(events)
        self.commands: list[dict[str, Any]] = []
        self.timeouts: list[tuple[float, str]] = []
        self.echo_empty_marks = echo_empty_marks
        self.echo_sequence = 10000

    def receive(self, *, timeout: float, timeout_name: str) -> ProbeMessage:
        assert timeout > 0
        assert timeout_name
        self.timeouts.append((timeout, timeout_name))
        if not self.events:
            if self.echo_empty_marks:
                threading.Event().wait(timeout)
            raise TimeoutError(f"{timeout_name} timed out")
        event = self.events.popleft()
        if isinstance(event, BaseException):
            raise event
        return event

    def send(self, command: dict[str, Any], **_: Any) -> None:
        self.commands.append(command)
        if (
            self.echo_empty_marks
            and command["type"] == "mark"
            and not self.events
        ):
            self.events.append(
                _message(self.echo_sequence, "mark", label=command["label"])
            )
            self.echo_sequence += 1


class MarkDrivenTransport(FakeTransport):
    def __init__(self, *, release_after_marks: int) -> None:
        super().__init__([])
        self.release_after_marks = release_after_marks
        self.released = threading.Event()
        self.sequence = 0

    def send(self, command: dict[str, Any], **_: Any) -> None:
        super().send(command)
        if command["type"] != "mark":
            return
        mark_count = sum(item["type"] == "mark" for item in self.commands)
        if mark_count == self.release_after_marks:
            origin = (100, 50)
            warp = (141, 79)
            for message, button in (
                (WM_MOUSEMOVE, 0),
                (WM_LBUTTONDOWN, 1),
                (WM_LBUTTONUP, 1),
            ):
                self.events.append(
                    _message(
                        self.sequence,
                        "mouse",
                        **_mouse_fields(
                            message=message,
                            button=button,
                            origin=origin,
                            warp=warp,
                        ),
                    )
                )
                self.sequence += 1
            self.released.set()
        self.events.append(
            _message(self.sequence, "mark", label=command["label"])
        )
        self.sequence += 1


class DeadlineOriginTransport(FakeTransport):
    def __init__(self) -> None:
        super().__init__([])
        self.sequence = 0
        self.waiter = threading.Event()

    def send(self, command: dict[str, Any], **_: Any) -> None:
        super().send(command)
        if command["type"] == "origin":
            self.events.append(
                _message(
                    self.sequence,
                    "origin",
                    x=0,
                    y=0,
                    virtual_x=0,
                    virtual_y=0,
                )
            )
            self.sequence += 1
        elif command["type"] == "mark":
            self.events.append(
                _message(self.sequence, "mark", label=command["label"])
            )
            self.sequence += 1

    def receive(self, *, timeout: float, timeout_name: str) -> ProbeMessage:
        if self.events:
            return super().receive(timeout=timeout, timeout_name=timeout_name)
        self.waiter.wait(timeout)
        raise TimeoutError(f"{timeout_name} timed out")


class SequenceOriginTransport(DeadlineOriginTransport):
    def __init__(self, origins: list[tuple[int, int]]) -> None:
        super().__init__()
        self.origins = deque(origins)

    def send(self, command: dict[str, Any], **_: Any) -> None:
        self.commands.append(command)
        if command["type"] == "origin":
            origin = self.origins.popleft()
            self.events.append(
                _message(
                    self.sequence,
                    "origin",
                    x=origin[0],
                    y=origin[1],
                    virtual_x=0,
                    virtual_y=0,
                )
            )
            self.sequence += 1
        elif command["type"] == "mark":
            self.events.append(
                _message(self.sequence, "mark", label=command["label"])
            )
            self.sequence += 1


def _mouse_fields(
    *,
    message: int,
    button: int,
    origin: tuple[int, int],
    warp: tuple[int, int],
    virtual: tuple[int, int] = (0, 0),
) -> dict[str, int]:
    client = (warp[0] - origin[0], warp[1] - origin[1])
    return {
        "x": client[0],
        "y": client[1],
        "client_x": client[0],
        "client_y": client[1],
        "screen_x": warp[0] + virtual[0],
        "screen_y": warp[1] + virtual[1],
        "cursor_x": warp[0] + virtual[0],
        "cursor_y": warp[1] + virtual[1],
        "origin_x": origin[0] + virtual[0],
        "origin_y": origin[1] + virtual[1],
        "virtual_x": virtual[0],
        "virtual_y": virtual[1],
        "message": message,
        "button": button,
    }


def _golden_traces(
    scenario: str,
    *,
    samples: int = 1,
    origin: tuple[int, int] = (317, 211),
    stale_origin_first: bool = False,
    missing_down_field: str | None = None,
    final_origin: tuple[int, int] | None = None,
    synthetic_target: int = 100,
) -> tuple[list[ProbeMessage], list[ProbeMessage]]:
    host: list[ProbeMessage] = []
    plugin: list[ProbeMessage] = []
    host_seq = 0
    plugin_seq = 0

    def host_event(kind: str, **fields: Any) -> None:
        nonlocal host_seq
        host.append(_message(host_seq, kind, **fields))
        host_seq += 1

    def plugin_event(kind: str, **fields: Any) -> None:
        nonlocal plugin_seq
        plugin.append(_message(plugin_seq, kind, **fields))
        plugin_seq += 1

    spec = scenario_spec(scenario)
    host_event("ready", mode=spec.hierarchy)
    if spec.preopen_warp:
        host_event("warped", x=41, y=29, state=0)
    host_event(
        "gui_opened",
        hwnd=102,
        outer=90 if spec.hierarchy != "flat" else 0,
        intermediate=91 if spec.hierarchy != "flat" else 0,
        clap_parent=100,
        wrapper=101,
        wine_window=102,
        hierarchy_offset_x=56 if spec.hierarchy != "flat" else 0,
        hierarchy_offset_y=64 if spec.hierarchy != "flat" else 0,
    )
    host_event("clap", event="gui_shown")

    plugin_event("hello", plugin_id="org.yabridge.coordprobe")
    plugin_event("attached", hwnd=500)
    plugin_event("origin", x=0, y=0, virtual_x=0, virtual_y=0)
    plugin_event("size", w=320, h=200)

    for index in range(samples):
        effective_origin = (origin[0] + index * 7, origin[1] + index * 5)
        warp = (effective_origin[0] + 41, effective_origin[1] + 29)
        host_event("geometry", x=effective_origin[0], y=effective_origin[1], w=320, h=200)
        host_event(
            "x11",
            window=102,
            x=effective_origin[0],
            y=effective_origin[1],
            w=320,
            h=200,
            parent_x=0,
            parent_y=0,
        )
        if spec.move_after_open:
            effective_origin = (effective_origin[0] + 37, effective_origin[1] + 23)
            warp = (effective_origin[0] + 41, effective_origin[1] + 29)
            host_event(
                "geometry", x=effective_origin[0], y=effective_origin[1], w=320, h=200
            )
            host_event(
                "x11",
                window=102,
                x=effective_origin[0],
                y=effective_origin[1],
                w=320,
                h=200,
                parent_x=0,
                parent_y=0,
            )
        elif spec.resize:
            host_event(
                "geometry", x=effective_origin[0], y=effective_origin[1], w=401, h=233
            )
            host_event(
                "x11",
                window=102,
                x=effective_origin[0],
                y=effective_origin[1],
                w=401,
                h=233,
                parent_x=0,
                parent_y=0,
            )
        elif spec.synthetic_absolute:
            host_event(
                "geometry",
                x=effective_origin[0],
                y=effective_origin[1],
                w=320,
                h=200,
                synthetic_send_event=True,
                event_x=effective_origin[0],
                event_y=effective_origin[1],
                synthetic_window=synthetic_target,
            )
            host_event(
                "x11",
                window=102,
                x=effective_origin[0],
                y=effective_origin[1],
                w=320,
                h=200,
                parent_x=0,
                parent_y=0,
                synthetic_send_event=True,
                event_x=effective_origin[0],
                event_y=effective_origin[1],
                synthetic_window=synthetic_target,
            )

        plugin_event("mark", label=f"{scenario}:{index}:boundary")
        if spec.synthetic_absolute:
            plugin_event(
                "origin",
                x=effective_origin[0],
                y=effective_origin[1],
                virtual_x=0,
                virtual_y=0,
            )
            plugin_event("mark", label=f"{scenario}:{index}:pre-synthetic")
        if stale_origin_first:
            plugin_event("origin", x=0, y=0, virtual_x=0, virtual_y=0)
            plugin_event("mark", label=f"{scenario}:{index}:origin:0")
            plugin_event(
                "origin",
                x=effective_origin[0],
                y=effective_origin[1],
                virtual_x=0,
                virtual_y=0,
            )
            plugin_event("mark", label=f"{scenario}:{index}:origin:1")
        else:
            plugin_event(
                "origin",
                x=effective_origin[0],
                y=effective_origin[1],
                virtual_x=0,
                virtual_y=0,
            )
            plugin_event("mark", label=f"{scenario}:{index}:origin:0")
        measured_origin = effective_origin if final_origin is None else final_origin
        plugin_event(
            "origin",
            x=measured_origin[0],
            y=measured_origin[1],
            virtual_x=0,
            virtual_y=0,
        )
        plugin_event("mark", label=f"{scenario}:{index}:final-origin")
        host_event(
            "geometry", x=effective_origin[0], y=effective_origin[1], w=320, h=200
        )
        host_event(
            "x11",
            window=102,
            x=effective_origin[0],
            y=effective_origin[1],
            w=320,
            h=200,
            parent_x=0,
            parent_y=0,
        )
        plugin_event("mark", label=f"{scenario}:{index}:events")

        host_event(
            "warped",
            x=warp[0],
            y=warp[1],
            button=1,
            press_observed=True,
            release_observed=True,
            press_state=256,
            release_state=0,
        )
        plugin_event(
            "mouse",
            **_mouse_fields(
                message=WM_MOUSEMOVE,
                button=0,
                origin=effective_origin,
                warp=warp,
                virtual=(-1920, 0),
            ),
        )
        down = _mouse_fields(
            message=WM_LBUTTONDOWN,
            button=1,
            origin=effective_origin,
            warp=warp,
            virtual=(-1920, 0),
        )
        if missing_down_field is not None:
            down.pop(missing_down_field)
        plugin_event("mouse", **down)
        plugin_event(
            "mouse",
            **_mouse_fields(
                message=WM_LBUTTONUP,
                button=1,
                origin=effective_origin,
                warp=warp,
                virtual=(-1920, 0),
            ),
        )
        plugin_event("mark", label=f"{scenario}:{index}:end")
    return host, plugin


@pytest.mark.parametrize(
    ("scenario", "expected_commands"),
    [
        ("origin", ["open", "place", "geometry", "button", "close"]),
        ("offset", ["open", "place", "geometry", "button", "close"]),
        (
            "move_after_open",
            ["open", "place", "place", "geometry", "button", "close"],
        ),
        (
            "pointer_inside_on_open",
            ["warp", "open", "place", "geometry", "button", "close"],
        ),
        ("nested", ["open", "place", "geometry", "button", "close"]),
        (
            "nested_synthetic_abs",
            [
                "open",
                "place",
                "synthetic_configure",
                "geometry",
                "button",
                "close",
            ],
        ),
        ("resize", ["open", "place", "resize", "geometry", "button", "close"]),
        ("wm_managed", ["open", "place", "geometry", "button", "close"]),
    ],
)
def test_all_scenarios_execute_distinct_golden_semantics(
    scenario: str, expected_commands: list[str]
) -> None:
    host_events, plugin_events = _golden_traces(scenario)
    host = FakeTransport(host_events)
    executor = ScenarioExecutor(
        host,
        FakeTransport(plugin_events),
        tolerance=2,
        samples=1,
        seed=7,
    )

    result = executor.run(scenario, BaselineState.passed())

    assert result.result is HarnessTestResult.PASS, result.model_dump()
    assert [command["type"] for command in host.commands] == expected_commands
    assert result.measurements is not None
    assert result.measurements["scenario_semantics"] == scenario_spec(scenario).as_dict()
    if scenario == "nested":
        assert result.measurements["host_geometry"]["hierarchy_offset"] == [56, 64]
    if scenario == "nested_synthetic_abs":
        x11 = result.measurements["host_geometry"]["independent_x11"]
        synthetic = result.measurements["synthetic_evidence"]
        assert synthetic["host_event"]["synthetic_send_event"] is True
        assert synthetic["host_event"]["synthetic_window"] == 100
        assert synthetic["pre_plugin_origin"] == [317, 211]
        assert synthetic["post_plugin_origin"] == [317, 211]
        assert synthetic["post_host_x11"] == x11


def test_motion_and_button_down_are_separate_evidence() -> None:
    host_events, plugin_events = _golden_traces("offset")
    result = ScenarioExecutor(
        FakeTransport(host_events),
        FakeTransport(plugin_events),
        tolerance=2,
        samples=1,
        seed=7,
    ).run("offset", BaselineState.passed())

    assert result.result is HarnessTestResult.PASS
    assert result.measurements is not None
    evidence = result.measurements["samples"][0]["plugin_evidence"]
    assert evidence["motion"]["message"] == WM_MOUSEMOVE
    assert evidence["motion"]["button"] == 0
    assert evidence["button_down"]["message"] == WM_LBUTTONDOWN
    assert evidence["button_down"]["button"] == 1
    assert evidence["button_up"]["message"] == WM_LBUTTONUP


def test_plugin_hello_uses_cold_start_deadline() -> None:
    host_events, plugin_events = _golden_traces("offset")
    plugin = FakeTransport(plugin_events)
    executor = ScenarioExecutor(
        FakeTransport(host_events),
        plugin,
        tolerance=2,
        samples=1,
        seed=7,
    )
    result = executor.run("offset", BaselineState.passed())

    assert result.result is HarnessTestResult.PASS
    hello_timeout = next(
        timeout for timeout, name in plugin.timeouts if name == "offset plugin hello"
    )
    assert executor.plugin_accept_deadline >= 30.0
    assert hello_timeout >= 29.9


def test_three_samples_drain_prior_buckets_without_foreign_events() -> None:
    host_events, plugin_events = _golden_traces("offset", samples=3)
    result = ScenarioExecutor(
        FakeTransport(host_events),
        FakeTransport(plugin_events),
        tolerance=2,
        samples=3,
        seed=7,
    ).run("offset", BaselineState.passed())

    assert result.result is HarnessTestResult.PASS, result.model_dump()
    assert result.measurements is not None
    assert len(result.measurements["samples"]) == 3
    for index, sample in enumerate(result.measurements["samples"]):
        assert sample["boundaries"]["end"] == f"offset:{index}:end"
        assert sample["plugin_evidence"]["button_up"]["message"] == WM_LBUTTONUP


def test_event_boundary_retries_until_xinput_reaches_gui_queue() -> None:
    host_events, plugin_events = _golden_traces("offset")
    first_mouse = next(
        index for index, message in enumerate(plugin_events) if message.type == "mouse"
    )
    original_end = plugin_events.pop()
    plugin_events.insert(first_mouse, original_end)
    plugin_events.append(_message(0, "mark", label="offset:0:end:1"))
    plugin_events = [
        _message(index, message.type, **message.fields)
        for index, message in enumerate(plugin_events)
    ]

    result = ScenarioExecutor(
        FakeTransport(host_events),
        FakeTransport(plugin_events),
        tolerance=2,
        samples=1,
        seed=7,
    ).run("offset", BaselineState.passed())

    assert result.result is HarnessTestResult.PASS
    assert result.measurements is not None
    assert result.measurements["samples"][0]["boundaries"]["end"] == "offset:0:end"


def test_delayed_input_after_more_than_eight_marks_is_collected() -> None:
    plugin = MarkDrivenTransport(release_after_marks=10)
    executor = ScenarioExecutor(
        FakeTransport([]),
        plugin,
        tolerance=2,
        samples=1,
        seed=7,
        deadline=0.2,
    )

    motion, down, up, _, _ = executor._plugin_evidence("offset", 0)

    assert plugin.released.is_set()
    assert motion is not None
    assert down is not None
    assert up is not None
    assert sum(command["type"] == "mark" for command in plugin.commands) == 10


def test_responsive_queue_without_button_down_is_completed_fail() -> None:
    host_events, plugin_events = _golden_traces("nested")
    plugin_events = [
        message
        for message in plugin_events
        if not (
            message.type == "mouse"
            and message.fields.get("message") == WM_LBUTTONDOWN
        )
    ]
    plugin_events = [
        _message(index, message.type, **message.fields)
        for index, message in enumerate(plugin_events)
    ]
    plugin = FakeTransport(plugin_events, echo_empty_marks=True)

    started = time.monotonic()
    result = ScenarioExecutor(
        FakeTransport(host_events),
        plugin,
        tolerance=2,
        samples=1,
        seed=7,
        deadline=0.02,
    ).run("nested", BaselineState.passed())
    elapsed = time.monotonic() - started

    assert result.result is HarnessTestResult.FAIL
    assert elapsed >= 0.018
    assert result.error is None
    assert result.measurements is not None
    assert result.measurements["classification"] == "missing_plugin_input_evidence"


def test_origin_convergence_retries_and_preserves_trace() -> None:
    plugin = SequenceOriginTransport([(0, 0), (317, 211)])
    executor = ScenarioExecutor(
        FakeTransport([]),
        plugin,
        tolerance=2,
        samples=1,
        seed=7,
        deadline=0.2,
    )

    origin, convergence = executor._converged_origin("offset", 0, (317, 211))

    assert origin == (317, 211)
    assert [attempt["normalized"] for attempt in convergence] == [[0, 0], [317, 211]]
    origin_commands = [command for command in plugin.commands if command["type"] == "origin"]
    assert len(origin_commands) == 2


def test_converged_readiness_does_not_replace_divergent_final_origin() -> None:
    host_events, plugin_events = _golden_traces("offset", final_origin=(0, 0))
    result = ScenarioExecutor(
        FakeTransport(host_events),
        FakeTransport(plugin_events),
        tolerance=2,
        samples=1,
        seed=7,
    ).run("offset", BaselineState.passed())

    assert result.result is HarnessTestResult.FAIL
    assert result.measurements is not None
    sample = result.measurements["samples"][0]
    assert sample["origin_readiness"][-1]["converged"] is True
    assert sample["plugin_origin"] == [0, 0]
    assert sample["host_geometry"]["independent_x11"]["x"] == 317


def test_origin_readiness_waits_until_actual_deadline() -> None:
    plugin = DeadlineOriginTransport()
    executor = ScenarioExecutor(
        FakeTransport([]),
        plugin,
        tolerance=2,
        samples=1,
        seed=7,
        deadline=0.06,
    )
    started = time.monotonic()

    origin, readiness = executor._converged_origin("nested", 0, (317, 211))

    elapsed = time.monotonic() - started
    assert elapsed >= 0.05
    assert origin == (0, 0)
    assert readiness[-1]["converged"] is False


def test_wrong_synthetic_target_is_started_error() -> None:
    host_events, plugin_events = _golden_traces(
        "nested_synthetic_abs", synthetic_target=101
    )
    result = ScenarioExecutor(
        FakeTransport(host_events),
        FakeTransport(plugin_events),
        tolerance=2,
        samples=1,
        seed=7,
    ).run("nested_synthetic_abs", BaselineState.passed())

    assert result.result is HarnessTestResult.ERROR
    assert "CLAP parent" in (result.error or "")


def test_synthetic_evidence_preserves_editor_log_tail(tmp_path: Path) -> None:
    host_events, plugin_events = _golden_traces("nested_synthetic_abs")
    log = tmp_path / "yabridge.log"
    log.write_text("editor: synthetic parent configure observed\n")
    result = ScenarioExecutor(
        FakeTransport(host_events),
        FakeTransport(plugin_events),
        tolerance=2,
        samples=1,
        seed=7,
        yabridge_log=log,
    ).run("nested_synthetic_abs", BaselineState.passed())

    assert result.result is HarnessTestResult.PASS
    assert result.measurements is not None
    synthetic = result.measurements["samples"][0]["synthetic_evidence"]
    assert "synthetic parent configure" in synthetic["yabridge_editor_log_tail"]


def test_missing_button_field_is_named_started_error() -> None:
    host_events, plugin_events = _golden_traces(
        "offset", missing_down_field="screen_x"
    )
    result = ScenarioExecutor(
        FakeTransport(host_events),
        FakeTransport(plugin_events),
        tolerance=2,
        samples=1,
        seed=7,
    ).run("offset", BaselineState.passed())

    assert result.result is HarnessTestResult.ERROR
    assert "button_down.screen_x" in (result.error or "")


def test_missing_virtual_origin_field_is_named_started_error() -> None:
    host_events, plugin_events = _golden_traces("offset")
    final_origin = next(
        message
        for message in plugin_events
        if message.type == "origin"
        and message.fields.get("x") == 317
        and message.fields.get("virtual_x") == 0
    )
    final_origin.fields.pop("virtual_x")
    result = ScenarioExecutor(
        FakeTransport(host_events),
        FakeTransport(plugin_events),
        tolerance=2,
        samples=1,
        seed=7,
    ).run("offset", BaselineState.passed())

    assert result.result is HarnessTestResult.ERROR
    assert "virtual_x" in (result.error or "")


def test_wrong_boundary_mark_is_rejected() -> None:
    host_events, plugin_events = _golden_traces("offset")
    plugin_events[4] = _message(4, "mark", label="offset:99:boundary")
    result = ScenarioExecutor(
        FakeTransport(host_events),
        FakeTransport(plugin_events),
        tolerance=2,
        samples=1,
        seed=7,
    ).run("offset", BaselineState.passed())

    assert result.result is HarnessTestResult.ERROR
    assert "stale or foreign mark" in (result.error or "")


def test_baseline_failure_prevents_bridged_pass() -> None:
    host_events, plugin_events = _golden_traces("offset")
    result = ScenarioExecutor(
        FakeTransport(host_events),
        FakeTransport(plugin_events),
        tolerance=2,
        samples=1,
        seed=7,
    ).run("offset", BaselineState.failed("pure-Wine coordinates diverged"))

    assert result.result is HarnessTestResult.ERROR
    assert result.measurements is not None
    assert result.measurements["baseline"]["result"] == "fail"


def test_explicit_missing_library_is_error_but_auto_missing_is_skip(tmp_path: Path) -> None:
    explicit = WineChildWindowTest(
        ProbeOptions(yabridge_lib=tmp_path / "typo.so"),
        environ={"HOME": str(tmp_path / "empty")},
    ).run_all()
    automatic = WineChildWindowTest(
        ProbeOptions(),
        environ={"HOME": str(tmp_path / "empty")},
    ).run_all()

    assert all(result.result is HarnessTestResult.ERROR for result in explicit)
    assert all(result.result is HarnessTestResult.SKIP for result in automatic)


def test_completed_results_survive_late_failure() -> None:
    completed = [SingleTestResult(name="probe_origin", result=HarnessTestResult.PASS)]
    results = WineChildWindowTest._append_unfinished_errors(
        completed,
        ("origin", "offset", "nested"),
        RuntimeError("late teardown failed"),
    )

    assert results[0].result is HarnessTestResult.PASS
    assert [(result.name, result.result) for result in results[1:]] == [
        ("probe_offset", HarnessTestResult.ERROR),
        ("probe_nested", HarnessTestResult.ERROR),
    ]


def test_temporary_prefix_cleanup_failure_preserves_completed_results() -> None:
    completed = [SingleTestResult(name="probe_origin", result=HarnessTestResult.PASS)]

    def fail_cleanup() -> None:
        raise OSError("temporary prefix cleanup failed")

    results = WineChildWindowTest._guard_final_cleanup(
        completed,
        ("origin", "offset"),
        fail_cleanup,
    )

    assert results[0].result is HarnessTestResult.PASS
    assert results[1].name == "probe_offset"
    assert results[1].result is HarnessTestResult.ERROR
    assert "temporary prefix cleanup failed" in (results[1].error or "")
    assert json.loads(
        json.dumps([result.model_dump(mode="json") for result in results])
    )[0]["result"] == "pass"


def test_external_prefix_never_kills_wineserver(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    calls: list[list[str]] = []
    monkeypatch.setattr(
        "yabridge_test.probe.runner.subprocess.run",
        lambda command, **kwargs: calls.append(command),
    )
    monkeypatch.setattr(
        "yabridge_test.probe.runner.shutil.which", lambda name: f"/usr/bin/{name}"
    )

    WineChildWindowTest._stop_owned_wineserver(
        prefix=tmp_path / "external",
        owned=False,
        environ={},
    )

    assert calls == []


def test_existing_display_requires_pointer_warp_opt_in() -> None:
    server = XServer(
        headless=False,
        allow_pointer_warp=False,
        environ={"DISPLAY": ":7"},
    )
    with pytest.raises(XServerError, match="explicit opt-in"):
        server.require_pointer_warp()


def test_display_allocator_locks_out_concurrent_collision(tmp_path: Path) -> None:
    lock_dir = tmp_path / "locks"
    socket_dir = tmp_path / "sockets"
    server_lock_dir = tmp_path / "server-locks"
    socket_dir.mkdir()
    server_lock_dir.mkdir()
    first = DisplayAllocator(
        lock_dir=lock_dir,
        socket_dir=socket_dir,
        server_lock_dir=server_lock_dir,
        numbers=range(90, 92),
    )
    second = DisplayAllocator(
        lock_dir=lock_dir,
        socket_dir=socket_dir,
        server_lock_dir=server_lock_dir,
        numbers=range(90, 92),
    )
    assert first.acquire() == 90
    assert second.acquire() == 91
    first.release()
    second.release()


@pytest.mark.live_probe
def test_live_offset_probe_opt_in(tmp_path: Path) -> None:
    library = os.environ.get("YABRIDGE_LIVE_LIB")
    if not library:
        pytest.skip("set YABRIDGE_LIVE_LIB to opt into the live yabridge probe")

    results = WineChildWindowTest(
        ProbeOptions(
            scenario="offset",
            yabridge_lib=Path(library),
            wine_prefix=tmp_path / "wine-prefix",
            headless=True,
        )
    ).run_all()

    assert len(results) == 1
    result = results[0]
    assert result.result in {HarnessTestResult.PASS, HarnessTestResult.FAIL}, result.model_dump()
    assert result.measurements is not None
    assert result.measurements["baseline"]["result"] == "pass"
