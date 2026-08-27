"""Bridged Wine child-window scenario orchestration."""

from __future__ import annotations

import os
import random
import shutil
import socket
import subprocess
import tempfile
import threading
import time
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Protocol

from ..schemas import SingleTestResult, TestResult
from .discovery import DiscoveryError, YabridgeIdentity, discover_yabridge
from .evaluator import ProbeSample, evaluate_sample
from .fixture import FixtureError, ProbeFixture
from .protocol import ProbeMessage, ProtocolError, ProtocolValidator, decode_message
from .scenarios import SCENARIO_NAMES
from .transport import HostProcess, PluginListener, TransportError

DEFAULT_TOLERANCE = 2
DEFAULT_SAMPLES = 1
DEFAULT_DEADLINE = 8.0
BASELINE_PROCESS_DEADLINE = 30.0
PLUGIN_ACCEPT_DEADLINE = 30.0
QUIESCENCE_SLICE = 0.05
DEFAULT_SEED = 409


class _Transport(Protocol):
    def receive(self, *, timeout: float, timeout_name: str) -> ProbeMessage: ...

    def send(
        self,
        command: Mapping[str, Any],
        *,
        timeout: float = 2.0,
        timeout_name: str = "probe command",
    ) -> None: ...


@dataclass(frozen=True)
class ProbeOptions:
    """User-controlled inputs for one probe matrix run."""

    scenario: str | None = None
    headless: bool = True
    yabridge_lib: Path | None = None
    wine_prefix: Path | None = None
    samples: int = DEFAULT_SAMPLES
    tolerance: int = DEFAULT_TOLERANCE
    allow_pointer_warp: bool = False
    seed: int = DEFAULT_SEED

    def __post_init__(self) -> None:
        if self.scenario is not None and self.scenario not in SCENARIO_NAMES:
            raise ValueError(f"unknown probe scenario: {self.scenario}")
        if self.samples < 1:
            raise ValueError("samples must be positive")
        if self.tolerance < 0:
            raise ValueError("tolerance must be nonnegative")


@dataclass(frozen=True)
class BaselineState:
    """Measured pure-Wine prerequisite state for bridged verdicts."""

    result: TestResult
    details: str
    measurements: Mapping[str, Any] = field(default_factory=dict)

    @classmethod
    def passed(cls, measurements: Mapping[str, Any] | None = None) -> BaselineState:
        return cls(TestResult.PASS, "pure-Wine baseline passed", measurements or {})

    @classmethod
    def failed(cls, details: str, measurements: Mapping[str, Any] | None = None) -> BaselineState:
        return cls(TestResult.FAIL, details, measurements or {})


@dataclass(frozen=True)
class ScenarioSpec:
    hierarchy: str = "flat"
    preopen_warp: bool = False
    move_after_open: bool = False
    synthetic_absolute: bool = False
    resize: bool = False
    wm_managed: bool = False

    def as_dict(self) -> dict[str, bool | str]:
        return {
            "hierarchy": self.hierarchy,
            "preopen_warp": self.preopen_warp,
            "move_after_open": self.move_after_open,
            "synthetic_absolute": self.synthetic_absolute,
            "resize": self.resize,
            "wm_managed": self.wm_managed,
        }


_SCENARIO_SPECS = {
    "origin": ScenarioSpec(),
    "offset": ScenarioSpec(),
    "move_after_open": ScenarioSpec(move_after_open=True),
    "pointer_inside_on_open": ScenarioSpec(preopen_warp=True),
    "nested": ScenarioSpec(hierarchy="nested"),
    "nested_synthetic_abs": ScenarioSpec(
        hierarchy="synthetic-absolute", synthetic_absolute=True
    ),
    "resize": ScenarioSpec(resize=True),
    "wm_managed": ScenarioSpec(wm_managed=True),
}


def scenario_spec(name: str) -> ScenarioSpec:
    try:
        return _SCENARIO_SPECS[name]
    except KeyError as exc:
        raise ValueError(f"unknown probe scenario: {name}") from exc


def _event_document(message: ProbeMessage) -> dict[str, Any]:
    return {"seq": message.seq, "type": message.type, **message.fields}


class ScenarioExecutor:
    """Execute one scenario over authenticated host and plugin transports."""

    def __init__(
        self,
        host: _Transport,
        plugin: _Transport,
        *,
        tolerance: int,
        samples: int,
        seed: int,
        deadline: float = DEFAULT_DEADLINE,
        plugin_accept_deadline: float = PLUGIN_ACCEPT_DEADLINE,
        quiescence_slice: float = QUIESCENCE_SLICE,
        identity: YabridgeIdentity | None = None,
        yabridge_log: Path | None = None,
    ) -> None:
        self.host = host
        self.plugin = plugin
        self.tolerance = tolerance
        self.samples = samples
        self.seed = seed
        self.deadline = deadline
        self.plugin_accept_deadline = plugin_accept_deadline
        self.quiescence_slice = quiescence_slice
        self.identity = identity
        self.yabridge_log = yabridge_log
        self.host_events: list[dict[str, Any]] = []
        self.plugin_events: list[dict[str, Any]] = []

    def _receive(
        self,
        transport: _Transport,
        source: str,
        expected: set[str],
        timeout_name: str,
        *,
        timeout: float | None = None,
    ) -> ProbeMessage:
        timeout = self.deadline if timeout is None else timeout
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(f"{timeout_name} timed out after {timeout:g} seconds")
            message = transport.receive(timeout=remaining, timeout_name=timeout_name)
            document = _event_document(message)
            target = self.host_events if source == "host" else self.plugin_events
            target.append(document)
            if message.type == "error":
                detail = message.fields.get("message")
                if not isinstance(detail, str):
                    raise ProtocolError(f"{source} error.message is missing or not a string")
                raise ProtocolError(f"{source} reported error: {detail}")
            if message.type in expected:
                return message

    @staticmethod
    def _integer(message: ProbeMessage, field: str, evidence: str) -> int:
        value = message.fields.get(field)
        if not isinstance(value, int) or isinstance(value, bool):
            raise ProtocolError(f"{evidence}.{field} is missing or not an integer")
        return value

    @classmethod
    def _point(
        cls,
        message: ProbeMessage,
        x_field: str,
        y_field: str,
        evidence: str,
        *,
        normalize_virtual: bool,
    ) -> tuple[int, int]:
        x = cls._integer(message, x_field, evidence)
        y = cls._integer(message, y_field, evidence)
        if not normalize_virtual:
            return x, y
        virtual_x = cls._integer(message, "virtual_x", evidence)
        virtual_y = cls._integer(message, "virtual_y", evidence)
        return x - virtual_x, y - virtual_y

    def _drain_to_mark(
        self,
        label: str,
        timeout_name: str,
        *,
        deadline: float | None = None,
    ) -> list[ProbeMessage]:
        bucket: list[ProbeMessage] = []
        while True:
            timeout = self.deadline
            if deadline is not None:
                timeout = deadline - time.monotonic()
                if timeout <= 0:
                    raise TimeoutError(
                        f"{timeout_name} timed out after {self.deadline:g} seconds"
                    )
            message = self._receive(
                self.plugin,
                "plugin",
                {"mark", "mouse", "origin", "size", "bye"},
                timeout_name,
                timeout=timeout,
            )
            if message.type != "mark":
                bucket.append(message)
                continue
            observed = message.fields.get("label")
            if observed != label:
                raise ProtocolError(
                    f"stale or foreign mark {observed!r}; expected {label!r}"
                )
            return bucket

    def _query_plugin_origin(
        self,
        label: str,
        evidence: str,
        *,
        deadline: float | None = None,
    ) -> tuple[tuple[int, int], list[ProbeMessage]]:
        self.plugin.send(
            {"type": "origin", "x": 0, "y": 0},
            timeout_name=f"{evidence} query",
        )
        self.plugin.send(
            {"type": "mark", "label": label},
            timeout_name=f"{evidence} boundary",
        )
        bucket = self._drain_to_mark(
            label,
            f"{evidence} marked response",
            deadline=deadline,
        )
        origins = [message for message in bucket if message.type == "origin"]
        if not origins:
            raise ProtocolError(f"{evidence} produced no origin event")
        return (
            self._point(
                origins[-1],
                "x",
                "y",
                evidence,
                normalize_virtual=True,
            ),
            bucket,
        )

    def _receive_plugin_quiescence(
        self,
        deadline: float,
        timeout_name: str,
    ) -> ProbeMessage | None:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return None
        try:
            return self._receive(
                self.plugin,
                "plugin",
                {"mark", "mouse", "origin", "size", "bye"},
                timeout_name,
                timeout=min(self.quiescence_slice, remaining),
            )
        except TimeoutError:
            return None

    @staticmethod
    def _placement(scenario: str, sample: int, seed: int) -> tuple[int, int, int, int]:
        if scenario == "origin":
            return 0, 0, 320, 200
        generator = random.Random(f"{seed}:{scenario}:{sample}")
        return generator.randint(180, 520), generator.randint(120, 340), 320, 200

    def _converged_origin(
        self,
        scenario: str,
        sample_index: int,
        expected: tuple[int, int],
    ) -> tuple[tuple[int, int], list[dict[str, Any]]]:
        convergence: list[dict[str, Any]] = []
        deadline = time.monotonic() + self.deadline
        attempt = 0
        latest: tuple[int, int] | None = None
        while time.monotonic() < deadline:
            remaining = deadline - time.monotonic()
            if latest is not None and remaining <= self.quiescence_slice:
                late_event = self._receive_plugin_quiescence(
                    deadline,
                    f"{scenario} origin readiness deadline",
                )
                if late_event is not None:
                    if late_event.type == "mark":
                        raise ProtocolError(
                            f"stale or foreign mark {late_event.fields.get('label')!r} "
                            "during origin readiness"
                        )
                    convergence[-1]["deadline_event"] = _event_document(late_event)
                    continue
                break
            label = f"{scenario}:{sample_index}:origin:{attempt}"
            origin, bucket = self._query_plugin_origin(
                label,
                f"{scenario}.readiness[{attempt}]",
                deadline=deadline,
            )
            latest = origin
            converged = (
                abs(origin[0] - expected[0]) <= self.tolerance
                and abs(origin[1] - expected[1]) <= self.tolerance
            )
            convergence.append(
                {
                    "attempt": attempt,
                    "normalized": list(origin),
                    "converged": converged,
                    "events": [_event_document(message) for message in bucket],
                }
            )
            if converged:
                return origin, convergence
            attempt += 1
            quiescence = self._receive_plugin_quiescence(
                deadline,
                f"{scenario} origin readiness quiescence",
            )
            if quiescence is not None:
                if quiescence.type == "mark":
                    raise ProtocolError(
                        f"stale or foreign mark {quiescence.fields.get('label')!r} "
                        "during origin readiness"
                    )
                convergence[-1]["quiescence_event"] = _event_document(quiescence)
        if latest is not None:
            return latest, convergence
        raise TimeoutError(
            f"{scenario} plugin origin convergence timed out after {self.deadline:g} seconds"
        )

    def _plugin_evidence(
        self,
        scenario: str,
        sample_index: int,
    ) -> tuple[
        ProbeMessage | None,
        ProbeMessage | None,
        ProbeMessage | None,
        list[dict[str, Any]],
        str,
    ]:
        bucket: list[ProbeMessage] = []
        deadline = time.monotonic() + self.deadline
        attempt = 0
        label = f"{scenario}:{sample_index}:end"
        motion: ProbeMessage | None = None
        down: ProbeMessage | None = None
        up: ProbeMessage | None = None
        while time.monotonic() < deadline:
            remaining = deadline - time.monotonic()
            if attempt > 0 and remaining <= self.quiescence_slice:
                late_event = self._receive_plugin_quiescence(
                    deadline,
                    f"{scenario} input evidence deadline",
                )
                if late_event is None:
                    break
                if late_event.type == "mark":
                    raise ProtocolError(
                        f"stale or foreign mark {late_event.fields.get('label')!r} "
                        "during input evidence"
                    )
                bucket.append(late_event)
                if late_event.type == "mouse":
                    message = late_event.fields.get("message")
                    button = late_event.fields.get("button")
                    if message == 0x0200 and button == 0 and motion is None:
                        motion = late_event
                    elif message == 0x0201 and button == 1 and down is None:
                        down = late_event
                    elif message == 0x0202 and button == 1 and up is None:
                        up = late_event
                if motion is not None and down is not None and up is not None:
                    return (
                        motion,
                        down,
                        up,
                        [_event_document(message) for message in bucket],
                        label,
                    )
                continue
            label = (
                f"{scenario}:{sample_index}:end"
                if attempt == 0
                else f"{scenario}:{sample_index}:end:{attempt}"
            )
            self.plugin.send(
                {"type": "mark", "label": label},
                timeout_name=f"{scenario} end boundary {attempt}",
            )
            bucket.extend(
                self._drain_to_mark(
                    label,
                    f"{scenario} event boundary {attempt}",
                    deadline=deadline,
                )
            )
            motion = next(
                (
                    message
                    for message in bucket
                    if message.type == "mouse"
                    and message.fields.get("button") == 0
                    and message.fields.get("message") == 0x0200
                ),
                None,
            )
            down = next(
                (
                    message
                    for message in bucket
                    if message.type == "mouse"
                    and message.fields.get("button") == 1
                    and message.fields.get("message") == 0x0201
                ),
                None,
            )
            up = next(
                (
                    message
                    for message in bucket
                    if message.type == "mouse"
                    and message.fields.get("button") == 1
                    and message.fields.get("message") == 0x0202
                ),
                None,
            )
            if motion is not None and down is not None and up is not None:
                return (
                    motion,
                    down,
                    up,
                    [_event_document(message) for message in bucket],
                    label,
                )
            attempt += 1
            while time.monotonic() < deadline:
                event = self._receive_plugin_quiescence(
                    deadline,
                    f"{scenario} input evidence quiescence",
                )
                if event is None:
                    break
                if event.type == "mark":
                    raise ProtocolError(
                        f"stale or foreign mark {event.fields.get('label')!r} "
                        "during input evidence"
                    )
                bucket.append(event)
                if event.type == "mouse":
                    message = event.fields.get("message")
                    button = event.fields.get("button")
                    if message == 0x0200 and button == 0 and motion is None:
                        motion = event
                    elif message == 0x0201 and button == 1 and down is None:
                        down = event
                    elif message == 0x0202 and button == 1 and up is None:
                        up = event
                if motion is not None and down is not None and up is not None:
                    return (
                        motion,
                        down,
                        up,
                        [_event_document(message) for message in bucket],
                        label,
                    )
        return (
            motion,
            down,
            up,
            [_event_document(message) for message in bucket],
            label,
        )

    def _measure_one(
        self,
        scenario: str,
        sample_index: int,
        opened: ProbeMessage,
    ) -> tuple[TestResult, str | None, dict[str, Any]]:
        spec = scenario_spec(scenario)
        place_x, place_y, width, height = self._placement(scenario, sample_index, self.seed)
        warp = (place_x + 41, place_y + 29)

        self.host.send(
            {"type": "place", "x": place_x, "y": place_y, "w": width, "h": height},
            timeout_name=f"{scenario} place command",
        )
        geometry = self._receive(
            self.host, "host", {"geometry"}, f"{scenario} host geometry"
        )
        x11 = self._receive(self.host, "host", {"x11"}, f"{scenario} independent X11 geometry")

        if spec.move_after_open:
            self.host.send(
                {
                    "type": "place",
                    "x": place_x + 37,
                    "y": place_y + 23,
                    "w": width,
                    "h": height,
                },
                timeout_name="move-after-open placement",
            )
            geometry = self._receive(
                self.host, "host", {"geometry"}, "move-after-open host geometry"
            )
            x11 = self._receive(
                self.host, "host", {"x11"}, "move-after-open independent X11 geometry"
            )
            warp = (int(x11.fields["x"]) + 41, int(x11.fields["y"]) + 29)
        elif spec.resize:
            self.host.send(
                {"type": "resize", "w": 401, "h": 233},
                timeout_name="resize command",
            )
            geometry = self._receive(
                self.host, "host", {"geometry"}, "resize accepted geometry"
            )
            x11 = self._receive(
                self.host, "host", {"x11"}, "resize independent X11 geometry"
            )
        boundary = f"{scenario}:{sample_index}:boundary"
        self.plugin.send(
            {"type": "mark", "label": boundary},
            timeout_name=f"{scenario} sample boundary",
        )
        discarded = self._drain_to_mark(
            boundary, f"{scenario} prior event boundary"
        )
        readiness_x11_origin = (
            self._integer(x11, "x", f"{scenario}.x11"),
            self._integer(x11, "y", f"{scenario}.x11"),
        )
        pre_synthetic_origin: tuple[int, int] | None = None
        synthetic_host_event: dict[str, Any] | None = None
        if spec.synthetic_absolute:
            pre_synthetic_origin, _ = self._query_plugin_origin(
                f"{scenario}:{sample_index}:pre-synthetic",
                f"{scenario}.pre_synthetic_origin",
            )
            self.host.send(
                {
                    "type": "synthetic_configure",
                    "x": place_x,
                    "y": place_y,
                    "w": width,
                    "h": height,
                },
                timeout_name="nested synthetic configure",
            )
            geometry = self._receive(
                self.host, "host", {"geometry"}, "nested synthetic geometry"
            )
            x11 = self._receive(
                self.host, "host", {"x11"}, "nested synthetic X11 geometry"
            )
            if x11.fields.get("synthetic_send_event") is not True:
                raise ProtocolError("nested synthetic host did not observe send_event=True")
            event_x = self._integer(x11, "event_x", "nested_synthetic_abs.x11")
            event_y = self._integer(x11, "event_y", "nested_synthetic_abs.x11")
            parent_x = self._integer(x11, "parent_x", "nested_synthetic_abs.x11")
            parent_y = self._integer(x11, "parent_y", "nested_synthetic_abs.x11")
            synthetic_window = self._integer(
                x11, "synthetic_window", "nested_synthetic_abs.x11"
            )
            clap_parent = self._integer(
                opened, "clap_parent", "nested_synthetic_abs.gui_opened"
            )
            if synthetic_window != clap_parent:
                raise ProtocolError(
                    "synthetic ConfigureNotify did not target the CLAP parent"
                )
            if (event_x, event_y) == (parent_x, parent_y):
                raise ProtocolError(
                    "nested synthetic absolute event did not differ from parent-relative geometry"
                )
            synthetic_host_event = dict(x11.fields)
            readiness_x11_origin = (
                self._integer(x11, "x", f"{scenario}.synthetic_x11"),
                self._integer(x11, "y", f"{scenario}.synthetic_x11"),
            )

        _, readiness = self._converged_origin(
            scenario, sample_index, readiness_x11_origin
        )
        plugin_origin, final_origin_bucket = self._query_plugin_origin(
            f"{scenario}:{sample_index}:final-origin",
            f"{scenario}.final_origin",
        )
        self.host.send(
            {"type": "geometry"},
            timeout_name=f"{scenario} final host geometry query",
        )
        geometry = self._receive(
            self.host, "host", {"geometry"}, f"{scenario} final host geometry"
        )
        x11 = self._receive(
            self.host, "host", {"x11"}, f"{scenario} final independent X11 geometry"
        )
        x11_origin = (
            self._integer(x11, "x", f"{scenario}.final_x11"),
            self._integer(x11, "y", f"{scenario}.final_x11"),
        )
        warp = (x11_origin[0] + 41, x11_origin[1] + 29)
        events_label = f"{scenario}:{sample_index}:events"
        self.plugin.send(
            {"type": "mark", "label": events_label},
            timeout_name=f"{scenario} event start boundary",
        )
        pre_events = self._drain_to_mark(
            events_label, f"{scenario} event start boundary"
        )

        self.host.send(
            {"type": "button", "x": warp[0], "y": warp[1], "button": 1},
            timeout_name=f"{scenario} XTest button command",
        )
        observed = self._receive(
            self.host, "host", {"warped"}, f"{scenario} XTest pointer evidence"
        )
        motion, button_down, button_up, event_bucket, end_label = self._plugin_evidence(
            scenario, sample_index
        )
        if not observed.fields.get("press_observed") or not observed.fields.get(
            "release_observed"
        ):
            raise ProtocolError("XTest button press/release was not independently observed")

        observed_warp = (
            self._integer(observed, "x", f"{scenario}.xtest"),
            self._integer(observed, "y", f"{scenario}.xtest"),
        )
        synthetic_evidence: dict[str, Any] | None = None
        if spec.synthetic_absolute:
            assert pre_synthetic_origin is not None
            assert synthetic_host_event is not None
            synthetic_evidence = {
                "pre_plugin_origin": list(pre_synthetic_origin),
                "host_event": synthetic_host_event,
                "post_plugin_origin": list(plugin_origin),
                "post_host_x11": dict(x11.fields),
                "post_converged": (
                    abs(plugin_origin[0] - x11_origin[0]) <= self.tolerance
                    and abs(plugin_origin[1] - x11_origin[1]) <= self.tolerance
                ),
            }
            if self.yabridge_log is not None and self.yabridge_log.is_file():
                synthetic_evidence["yabridge_editor_log_tail"] = (
                    self.yabridge_log.read_text(errors="replace")[-16384:]
                )
        if motion is None or button_down is None or button_up is None:
            evidence = {
                "motion": _event_document(motion) if motion is not None else None,
                "button_down": (
                    _event_document(button_down) if button_down is not None else None
                ),
                "button_up": _event_document(button_up) if button_up is not None else None,
                "bucket": event_bucket,
            }
            missing = [
                name
                for name, message in (
                    ("WM_MOUSEMOVE", motion),
                    ("WM_LBUTTONDOWN", button_down),
                    ("WM_LBUTTONUP", button_up),
                )
                if message is None
            ]
            return (
                TestResult.FAIL,
                "missing_plugin_input_evidence",
                {
                    "x11_origin": list(x11_origin),
                    "warp": list(observed_warp),
                    "host_geometry": {
                        "clap_parent": opened.fields.get("clap_parent"),
                        "wrapper": opened.fields.get("wrapper"),
                        "wine_window": opened.fields.get("wine_window"),
                        "hierarchy_offset": [
                            opened.fields.get("hierarchy_offset_x", 0),
                            opened.fields.get("hierarchy_offset_y", 0),
                        ],
                        "reported": dict(geometry.fields),
                        "independent_x11": dict(x11.fields),
                    },
                    "plugin_origin": list(plugin_origin),
                    "xtest": dict(observed.fields),
                    "plugin_evidence": evidence,
                    "origin_readiness": readiness,
                    "final_origin_events": [
                        _event_document(message) for message in final_origin_bucket
                    ],
                    "boundaries": {
                        "start": boundary,
                        "events": events_label,
                        "end": end_label,
                    },
                    "missing_plugin_events": missing,
                    "assertions": [
                        {
                            "name": "plugin_input_delivery",
                            "result": TestResult.FAIL.value,
                            "expected": [
                                "WM_MOUSEMOVE",
                                "WM_LBUTTONDOWN",
                                "WM_LBUTTONUP",
                            ],
                            "actual": [
                                name
                                for name, message in (
                                    ("WM_MOUSEMOVE", motion),
                                    ("WM_LBUTTONDOWN", button_down),
                                    ("WM_LBUTTONUP", button_up),
                                )
                                if message is not None
                            ],
                        }
                    ],
                    **(
                        {"synthetic_evidence": synthetic_evidence}
                        if synthetic_evidence is not None
                        else {}
                    ),
                },
            )
        motion_client = self._point(
            motion, "client_x", "client_y", "motion", normalize_virtual=False
        )
        button_client = self._point(
            button_down,
            "client_x",
            "client_y",
            "button_down",
            normalize_virtual=False,
        )
        plugin_screen = self._point(
            button_down,
            "screen_x",
            "screen_y",
            "button_down",
            normalize_virtual=True,
        )
        cursor = self._point(
            button_down,
            "cursor_x",
            "cursor_y",
            "button_down",
            normalize_virtual=True,
        )
        virtual_origin = self._point(
            button_down,
            "virtual_x",
            "virtual_y",
            "button_down",
            normalize_virtual=False,
        )
        sample = ProbeSample(
            x11_origin=x11_origin,
            warp=observed_warp,
            motion_client=motion_client,
            button_down_client=button_client,
            plugin_origin=plugin_origin,
            plugin_screen=plugin_screen,
            cursor=cursor,
            virtual_screen_origin=virtual_origin,
        )
        verdict = evaluate_sample(sample, self.tolerance)
        measurements = dict(verdict.measurements)
        measurements.update(
            {
                "host_geometry": {
                    "clap_parent": opened.fields.get("clap_parent"),
                    "wrapper": opened.fields.get("wrapper"),
                    "wine_window": opened.fields.get("wine_window"),
                    "hierarchy_offset": [
                        opened.fields.get("hierarchy_offset_x", 0),
                        opened.fields.get("hierarchy_offset_y", 0),
                    ],
                    "reported": dict(geometry.fields),
                    "independent_x11": dict(x11.fields),
                },
                "plugin_origin": list(plugin_origin),
                "xtest": dict(observed.fields),
                "plugin_evidence": {
                    "motion": _event_document(motion),
                    "button_down": _event_document(button_down),
                    "button_up": _event_document(button_up),
                    "bucket": event_bucket,
                },
                "origin_readiness": readiness,
                "final_origin_events": [
                    _event_document(message) for message in final_origin_bucket
                ],
                "boundaries": {
                    "start": boundary,
                    "events": events_label,
                    "end": end_label,
                },
                "discarded_prior_bucket": [
                    _event_document(message) for message in discarded
                ],
                "discarded_pre_event_bucket": [
                    _event_document(message) for message in pre_events
                ],
                **(
                    {"synthetic_evidence": synthetic_evidence}
                    if synthetic_evidence is not None
                    else {}
                ),
            }
        )
        return verdict.result, verdict.classification, measurements

    def run(self, scenario: str, baseline: BaselineState) -> SingleTestResult:
        """Run a named scenario, converting started failures to ERROR."""
        started = time.monotonic()
        try:
            self._receive(self.host, "host", {"ready"}, f"{scenario} host ready")
            spec = scenario_spec(scenario)
            if spec.preopen_warp:
                self.host.send(
                    {"type": "warp", "x": 41, "y": 29},
                    timeout_name="pointer-inside pre-open warp",
                )
                self._receive(
                    self.host,
                    "host",
                    {"warped"},
                    "pointer-inside pre-open pointer evidence",
                )
            self.host.send({"type": "open"}, timeout_name=f"{scenario} open command")
            opened = self._receive(
                self.host, "host", {"gui_opened"}, f"{scenario} GUI open"
            )
            hello = self._receive(
                self.plugin,
                "plugin",
                {"hello"},
                f"{scenario} plugin hello",
                timeout=self.plugin_accept_deadline,
            )
            if hello.fields.get("plugin_id") != "org.yabridge.coordprobe":
                raise ProtocolError("foreign plugin connected to probe listener")
            self._receive(
                self.plugin, "plugin", {"attached"}, f"{scenario} plugin attachment"
            )

            outcomes: list[TestResult] = []
            sample_measurements: list[dict[str, Any]] = []
            classification: str | None = None
            for sample_index in range(self.samples):
                result, current_classification, measurements = self._measure_one(
                    scenario, sample_index, opened
                )
                outcomes.append(result)
                sample_measurements.append(measurements)
                classification = classification or current_classification
            self.host.send({"type": "close"}, timeout_name=f"{scenario} close command")

            if baseline.result is not TestResult.PASS:
                overall = TestResult.ERROR
                detail = f"bridged verdict suppressed: {baseline.details}"
            elif TestResult.ERROR in outcomes:
                overall = TestResult.ERROR
                detail = "one or more samples lacked required evidence"
            elif TestResult.FAIL in outcomes:
                overall = TestResult.FAIL
                detail = classification or "coordinate assertion failed"
            else:
                overall = TestResult.PASS
                detail = "all coordinate assertions passed"

            result_measurements: dict[str, Any] = {
                **(sample_measurements[-1] if sample_measurements else {}),
                "samples": sample_measurements,
                "raw_events": {
                    "host": self.host_events,
                    "plugin": self.plugin_events,
                },
                "baseline": {
                    "result": baseline.result.value,
                    "details": baseline.details,
                    "measurements": dict(baseline.measurements),
                },
                "seed": self.seed,
                "tolerance": self.tolerance,
                "scenario_semantics": spec.as_dict(),
            }
            if classification is not None:
                result_measurements["classification"] = classification
            if self.identity is not None:
                result_measurements["yabridge"] = {
                    "library": str(self.identity.library_path),
                    "mode": self.identity.mode,
                    "version": self.identity.version,
                    "sha256": self.identity.sha256,
                }
            if self.yabridge_log is not None and self.yabridge_log.is_file():
                result_measurements["yabridge_log_tail"] = self.yabridge_log.read_text(
                    errors="replace"
                )[-16384:]
            return SingleTestResult(
                name=f"probe_{scenario}",
                result=overall,
                details=detail,
                duration_ms=round((time.monotonic() - started) * 1000),
                measurements=result_measurements,
            )
        except (
            KeyError,
            OSError,
            ProtocolError,
            TimeoutError,
            TransportError,
            TypeError,
            ValueError,
        ) as exc:
            return SingleTestResult(
                name=f"probe_{scenario}",
                result=TestResult.ERROR,
                details="probe started but required measurements were not completed",
                duration_ms=round((time.monotonic() - started) * 1000),
                error=str(exc),
                measurements={
                    "raw_events": {
                        "host": self.host_events,
                        "plugin": self.plugin_events,
                    },
                    "baseline": {
                        "result": baseline.result.value,
                        "details": baseline.details,
                    },
                    "seed": self.seed,
                    "tolerance": self.tolerance,
                    "scenario_semantics": scenario_spec(scenario).as_dict(),
                },
            )


_runner_lock = threading.Lock()


def _xtest_click(display_name: str, x: int, y: int) -> tuple[int, int]:
    try:
        x11 = __import__("ctypes").CDLL("libX11.so.6")
        xtst = __import__("ctypes").CDLL("libXtst.so.6")
    except OSError as exc:
        raise RuntimeError("libX11 and libXtst are required for baseline pointer evidence") from exc
    import ctypes

    x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
    x11.XOpenDisplay.restype = ctypes.c_void_p
    x11.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
    x11.XDefaultRootWindow.restype = ctypes.c_ulong
    x11.XQueryPointer.argtypes = [
        ctypes.c_void_p,
        ctypes.c_ulong,
        ctypes.POINTER(ctypes.c_ulong),
        ctypes.POINTER(ctypes.c_ulong),
        ctypes.POINTER(ctypes.c_int),
        ctypes.POINTER(ctypes.c_int),
        ctypes.POINTER(ctypes.c_int),
        ctypes.POINTER(ctypes.c_int),
        ctypes.POINTER(ctypes.c_uint),
    ]
    x11.XSync.argtypes = [ctypes.c_void_p, ctypes.c_int]
    x11.XCloseDisplay.argtypes = [ctypes.c_void_p]
    xtst.XTestFakeMotionEvent.argtypes = [
        ctypes.c_void_p,
        ctypes.c_int,
        ctypes.c_int,
        ctypes.c_int,
        ctypes.c_ulong,
    ]
    xtst.XTestFakeButtonEvent.argtypes = [
        ctypes.c_void_p,
        ctypes.c_uint,
        ctypes.c_int,
        ctypes.c_ulong,
    ]
    display = x11.XOpenDisplay(display_name.encode())
    if not display:
        raise RuntimeError(f"could not open {display_name} for baseline XTest")
    try:
        if not xtst.XTestFakeMotionEvent(display, -1, x, y, 0):
            raise RuntimeError("baseline XTest motion failed")
        if not xtst.XTestFakeButtonEvent(display, 1, 1, 0):
            raise RuntimeError("baseline XTest button press failed")
        if not xtst.XTestFakeButtonEvent(display, 1, 0, 0):
            raise RuntimeError("baseline XTest button release failed")
        x11.XSync(display, 0)
        root = ctypes.c_ulong()
        child = ctypes.c_ulong()
        root_x = ctypes.c_int()
        root_y = ctypes.c_int()
        local_x = ctypes.c_int()
        local_y = ctypes.c_int()
        state = ctypes.c_uint()
        root_window = x11.XDefaultRootWindow(display)
        if not x11.XQueryPointer(
            display,
            root_window,
            ctypes.byref(root),
            ctypes.byref(child),
            ctypes.byref(root_x),
            ctypes.byref(root_y),
            ctypes.byref(local_x),
            ctypes.byref(local_y),
            ctypes.byref(state),
        ):
            raise RuntimeError("baseline XQueryPointer failed")
        return root_x.value, root_y.value
    finally:
        x11.XCloseDisplay(display)


def _baseline_command(token: str, sequence: int, kind: str, **fields: Any) -> bytes:
    import json

    return (
        json.dumps(
            {"v": 1, "seq": sequence, "type": kind, "token": token, **fields},
            separators=(",", ":"),
        )
        + "\n"
    ).encode()


def _run_pure_wine_baseline(
    *,
    wine: str,
    selftest: Path,
    windows_plugin: Path,
    display: str,
    prefix: Path,
    tolerance: int,
    base_environ: Mapping[str, str],
) -> BaselineState:
    """Run the Windows probe directly under Wine before involving yabridge."""
    token = __import__("secrets").token_urlsafe(32)
    events: list[dict[str, Any]] = []
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as server:
        server.bind(("127.0.0.1", 0))
        server.listen(2)
        server.settimeout(BASELINE_PROCESS_DEADLINE)
        endpoint = f"127.0.0.1:{server.getsockname()[1]}"
        env = {
            **base_environ,
            "DISPLAY": display,
            "WINEPREFIX": str(prefix),
            "WINEARCH": "win64",
            "WINEDEBUG": "-all",
            "WINEDLLOVERRIDES": "mscoree,mshtml=",
            "YABRIDGE_PROBE_ENDPOINT": endpoint,
            "YABRIDGE_PROBE_TOKEN": token,
        }
        process = subprocess.Popen(
            [wine, str(selftest), str(windows_plugin)],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
        baseline_passed = True
        try:
            for cycle in range(2):
                connection, _ = server.accept()
                connection.settimeout(DEFAULT_DEADLINE)
                validator = ProtocolValidator(token)
                current_origin: tuple[int, int] | None = None
                marked = False
                mouse: ProbeMessage | None = None
                with connection, connection.makefile("rb") as stream:
                    while current_origin is None:
                        line = stream.readline(65537)
                        if not line:
                            raise TransportError("pure-Wine baseline closed before origin")
                        message = decode_message(line)
                        validator.validate(message)
                        events.append({"cycle": cycle, **_event_document(message)})
                        if message.type == "error":
                            raise ProtocolError(
                                f"pure-Wine plugin error: {message.fields['message']}"
                            )
                        if message.type == "origin":
                            current_origin = (
                                int(message.fields["x"]),
                                int(message.fields["y"]),
                            )
                    label = f"baseline:{cycle}"
                    connection.sendall(_baseline_command(token, 0, "mark", label=label))
                    connection.sendall(_baseline_command(token, 1, "origin", x=0, y=0))
                    while not marked:
                        line = stream.readline(65537)
                        if not line:
                            raise TransportError("pure-Wine baseline closed before mark")
                        message = decode_message(line)
                        validator.validate(message)
                        events.append({"cycle": cycle, **_event_document(message)})
                        if message.type == "mark":
                            if message.fields.get("label") != label:
                                raise ProtocolError("pure-Wine baseline observed a foreign mark")
                            marked = True
                        elif message.type == "origin":
                            current_origin = (
                                int(message.fields["x"]),
                                int(message.fields["y"]),
                            )
                    assert current_origin is not None
                    target = (current_origin[0] + 41, current_origin[1] + 29)
                    observed_pointer = _xtest_click(display, *target)
                    while mouse is None:
                        line = stream.readline(65537)
                        if not line:
                            raise TransportError("pure-Wine baseline closed before mouse event")
                        message = decode_message(line)
                        validator.validate(message)
                        events.append({"cycle": cycle, **_event_document(message)})
                        if message.type == "mouse" and int(message.fields.get("button", 0)) == 1:
                            mouse = message
                    actual_client = (
                        int(mouse.fields["client_x"]),
                        int(mouse.fields["client_y"]),
                    )
                    actual_screen = (
                        int(mouse.fields["screen_x"]),
                        int(mouse.fields["screen_y"]),
                    )
                    if (
                        abs(actual_client[0] - 41) > tolerance
                        or abs(actual_client[1] - 29) > tolerance
                        or abs(actual_screen[0] - target[0]) > tolerance
                        or abs(actual_screen[1] - target[1]) > tolerance
                        or abs(observed_pointer[0] - target[0]) > tolerance
                        or abs(observed_pointer[1] - target[1]) > tolerance
                    ):
                        baseline_passed = False
            stdout, stderr = process.communicate(timeout=BASELINE_PROCESS_DEADLINE)
            if process.returncode != 0:
                raise TransportError(
                    "pure-Wine baseline exited with status "
                    f"{process.returncode}: {(stdout + stderr).decode(errors='replace')[-4096:]}"
                )
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=2)
            if process.stdout is not None:
                process.stdout.close()
            if process.stderr is not None:
                process.stderr.close()

    measurements = {"raw_events": events, "cycles": 2, "tolerance": tolerance}
    if baseline_passed:
        return BaselineState.passed(measurements)
    return BaselineState.failed("pure-Wine coordinate assertions failed", measurements)


class WineChildWindowTest:
    """Discover prerequisites and run the bridged scenario matrix sequentially."""

    def __init__(
        self,
        options: ProbeOptions | None = None,
        *,
        environ: Mapping[str, str] | None = None,
    ) -> None:
        self.options = options or ProbeOptions()
        self.environ = dict(os.environ if environ is None else environ)

    @property
    def scenarios(self) -> Sequence[str]:
        return (self.options.scenario,) if self.options.scenario else SCENARIO_NAMES

    @staticmethod
    def _repo_root() -> Path:
        return Path(__file__).resolve().parents[4]

    def _prerequisites(self) -> tuple[YabridgeIdentity, Path, Path, Path]:
        identity = discover_yabridge(self.options.yabridge_lib, environ=self.environ)
        root = self._repo_root()
        host = root / "probe" / "build-native" / "clap-probe-host"
        windows_plugin = root / "probe" / "build-win" / "coordprobe.clap-win"
        wine_selftest = root / "probe" / "build-win" / "coordprobe-selftest.exe"
        missing = [
            str(path)
            for path in (host, windows_plugin, wine_selftest)
            if not path.is_file() or not os.access(path, os.R_OK)
        ]
        required_commands = ["wine", "wineserver"]
        if self.options.headless:
            required_commands.extend(["Xvfb", "xdpyinfo"])
        missing.extend(command for command in required_commands if shutil.which(command) is None)
        if missing:
            raise FixtureError("missing prerequisite: " + ", ".join(missing))
        return identity, host, windows_plugin, wine_selftest

    def _wm_prerequisite_result(self) -> SingleTestResult | None:
        missing = [name for name in ("openbox", "xprop") if shutil.which(name) is None]
        if not missing:
            return None
        return SingleTestResult(
            name="probe_wm_managed",
            result=TestResult.SKIP,
            details="missing prerequisite: " + ", ".join(missing),
        )

    @staticmethod
    def _append_unfinished_errors(
        completed: list[SingleTestResult],
        scenarios: Sequence[str],
        error: BaseException,
    ) -> list[SingleTestResult]:
        completed_names = {result.name for result in completed}
        for scenario in scenarios:
            name = f"probe_{scenario}"
            if name not in completed_names:
                completed.append(
                    SingleTestResult(
                        name=name,
                        result=TestResult.ERROR,
                        details="probe startup began but this scenario did not complete",
                        error=str(error),
                    )
                )
        return completed

    @classmethod
    def _guard_final_cleanup(
        cls,
        completed: list[SingleTestResult],
        scenarios: Sequence[str],
        cleanup: Callable[[], None],
    ) -> list[SingleTestResult]:
        try:
            cleanup()
        except OSError as exc:
            cls._append_unfinished_errors(completed, scenarios, exc)
        return completed

    @staticmethod
    def _stop_owned_wineserver(
        *,
        prefix: Path,
        owned: bool,
        environ: Mapping[str, str],
    ) -> None:
        if not owned:
            return
        wineserver = shutil.which("wineserver")
        if wineserver is None:
            return
        subprocess.run(
            [wineserver, "-k"],
            env={**environ, "WINEPREFIX": str(prefix)},
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
            timeout=10,
        )

    def _run_live(
        self,
        identity: YabridgeIdentity,
        host_binary: Path,
        windows_plugin_source: Path,
        wine_selftest: Path,
    ) -> list[SingleTestResult]:
        from .xserver import XServer

        results: list[SingleTestResult] = []
        temporary_prefix = (
            tempfile.TemporaryDirectory(prefix="yabridge-probe-prefix-")
            if self.options.wine_prefix is None
            else None
        )
        prefix = (
            Path(temporary_prefix.name)
            if temporary_prefix is not None
            else self.options.wine_prefix
        )
        assert prefix is not None
        try:
            with XServer(
                headless=self.options.headless,
                wm_managed=False,
                allow_pointer_warp=self.options.allow_pointer_warp,
                environ=self.environ,
            ) as xserver:
                xserver.require_pointer_warp()
                with ProbeFixture(identity, windows_plugin_source) as fixture:
                    wine = shutil.which("wine")
                    assert wine is not None
                    baseline = _run_pure_wine_baseline(
                        wine=wine,
                        selftest=wine_selftest,
                        windows_plugin=fixture.windows_plugin,
                        display=xserver.display,
                        prefix=prefix,
                        tolerance=self.options.tolerance,
                        base_environ=self.environ,
                    )
                    debug_file = fixture.directory / "yabridge.log"
                    for scenario in self.scenarios:
                        if scenario == "wm_managed":
                            wm_skip = self._wm_prerequisite_result()
                            if wm_skip is not None:
                                results.append(wm_skip)
                                continue
                            xserver.start_window_manager()
                        hierarchy = scenario_spec(scenario).hierarchy
                        listener = PluginListener(accept_timeout=30.0)
                        env = {
                            **self.environ,
                            "DISPLAY": xserver.display,
                            "WINEPREFIX": str(prefix),
                            "YABRIDGE_PROBE_ENDPOINT": listener.endpoint,
                            "YABRIDGE_PROBE_TOKEN": listener.token,
                            "YABRIDGE_DEBUG_LEVEL": "1+editor",
                            "YABRIDGE_DEBUG_FILE": str(debug_file),
                        }
                        listener.start()
                        host: HostProcess | None = None
                        try:
                            host = HostProcess(
                                [
                                    str(host_binary),
                                    "--plugin",
                                    str(fixture.native_plugin),
                                    "--hierarchy",
                                    hierarchy,
                                ],
                                token=listener.token,
                                env=env,
                            )
                            result = ScenarioExecutor(
                                host,
                                listener,
                                tolerance=self.options.tolerance,
                                samples=self.options.samples,
                                seed=self.options.seed,
                                identity=identity,
                                yabridge_log=debug_file,
                            ).run(scenario, baseline)
                            results.append(result)
                        except (
                            OSError,
                            RuntimeError,
                            ProtocolError,
                            TimeoutError,
                            TransportError,
                            subprocess.SubprocessError,
                        ) as exc:
                            self._append_unfinished_errors(results, (scenario,), exc)
                        finally:
                            try:
                                listener.close()
                                if host is not None:
                                    host.close()
                            except (OSError, RuntimeError, TransportError) as exc:
                                self._append_unfinished_errors(results, (scenario,), exc)
        except (
            OSError,
            RuntimeError,
            ProtocolError,
            TimeoutError,
            TransportError,
            subprocess.SubprocessError,
        ) as exc:
            self._append_unfinished_errors(results, self.scenarios, exc)
        finally:
            try:
                self._stop_owned_wineserver(
                    prefix=prefix,
                    owned=temporary_prefix is not None,
                    environ=self.environ,
                )
            except (OSError, subprocess.SubprocessError) as exc:
                self._append_unfinished_errors(results, self.scenarios, exc)
            if temporary_prefix is not None:
                self._guard_final_cleanup(
                    results,
                    self.scenarios,
                    temporary_prefix.cleanup,
                )
        return results

    def run_all(self) -> list[SingleTestResult]:
        """Run selected scenarios, classifying only pre-start omissions as SKIP."""
        try:
            identity, host, windows_plugin, wine_selftest = self._prerequisites()
        except DiscoveryError as exc:
            result = (
                TestResult.ERROR
                if self.options.yabridge_lib is not None
                else TestResult.SKIP
            )
            reason = (
                "explicit yabridge library is invalid"
                if result is TestResult.ERROR
                else "missing prerequisite"
            )
            return [
                SingleTestResult(
                    name=f"probe_{scenario}",
                    result=result,
                    details=f"{reason}: {exc}",
                    error=str(exc) if result is TestResult.ERROR else None,
                )
                for scenario in self.scenarios
            ]
        except (FixtureError, OSError) as exc:
            return [
                SingleTestResult(
                    name=f"probe_{scenario}",
                    result=TestResult.SKIP,
                    details=f"missing prerequisite: {exc}",
                )
                for scenario in self.scenarios
            ]

        if not _runner_lock.acquire(blocking=False):
            return [
                SingleTestResult(
                    name=f"probe_{scenario}",
                    result=TestResult.ERROR,
                    details="probe runner is already active in this process",
                )
                for scenario in self.scenarios
            ]
        try:
            return self._run_live(identity, host, windows_plugin, wine_selftest)
        finally:
            _runner_lock.release()
