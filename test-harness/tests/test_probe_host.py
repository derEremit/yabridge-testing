"""Native X11 integration tests for the minimal CLAP probe host."""

from __future__ import annotations

import ctypes
import ctypes.util
import json
import os
import select
import shutil
import signal
import subprocess
import threading
import time
from collections.abc import Iterator
from pathlib import Path

import pytest

from yabridge_test.probe.protocol import MAX_LINE_BYTES, ProbeMessage
from yabridge_test.probe.transport import HostProcess

pytestmark = pytest.mark.native_probe

TOKEN = "native-host-secret"
HOST = Path(__file__).parents[2] / "probe" / "build-native" / "clap-probe-host"
FIXTURE = Path(__file__).parents[2] / "probe" / "build-native" / "native-clap-fixture.so"

BUTTON_PRESS = 4
BUTTON_RELEASE = 5
CONFIGURE_NOTIFY = 22
BUTTON_PRESS_MASK = 1 << 2
BUTTON_RELEASE_MASK = 1 << 3
STRUCTURE_NOTIFY_MASK = 1 << 17


class _XButtonEvent(ctypes.Structure):
    _fields_ = [
        ("type", ctypes.c_int),
        ("serial", ctypes.c_ulong),
        ("send_event", ctypes.c_int),
        ("display", ctypes.c_void_p),
        ("window", ctypes.c_ulong),
        ("root", ctypes.c_ulong),
        ("subwindow", ctypes.c_ulong),
        ("time", ctypes.c_ulong),
        ("x", ctypes.c_int),
        ("y", ctypes.c_int),
        ("x_root", ctypes.c_int),
        ("y_root", ctypes.c_int),
        ("state", ctypes.c_uint),
        ("button", ctypes.c_uint),
        ("same_screen", ctypes.c_int),
    ]


class _XConfigureEvent(ctypes.Structure):
    _fields_ = [
        ("type", ctypes.c_int),
        ("serial", ctypes.c_ulong),
        ("send_event", ctypes.c_int),
        ("display", ctypes.c_void_p),
        ("event", ctypes.c_ulong),
        ("window", ctypes.c_ulong),
        ("x", ctypes.c_int),
        ("y", ctypes.c_int),
        ("width", ctypes.c_int),
        ("height", ctypes.c_int),
        ("border_width", ctypes.c_int),
        ("above", ctypes.c_ulong),
        ("override_redirect", ctypes.c_int),
    ]


class _X11:
    def __init__(self, display_name: str) -> None:
        library = ctypes.util.find_library("X11")
        if library is None:
            pytest.skip("missing native prerequisite: libX11")
        self.lib = ctypes.CDLL(library)
        self.lib.XOpenDisplay.argtypes = [ctypes.c_char_p]
        self.lib.XOpenDisplay.restype = ctypes.c_void_p
        self.lib.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
        self.lib.XDefaultRootWindow.restype = ctypes.c_ulong
        self.lib.XGetGeometry.argtypes = [
            ctypes.c_void_p,
            ctypes.c_ulong,
            ctypes.POINTER(ctypes.c_ulong),
            ctypes.POINTER(ctypes.c_int),
            ctypes.POINTER(ctypes.c_int),
            ctypes.POINTER(ctypes.c_uint),
            ctypes.POINTER(ctypes.c_uint),
            ctypes.POINTER(ctypes.c_uint),
            ctypes.POINTER(ctypes.c_uint),
        ]
        self.lib.XTranslateCoordinates.argtypes = [
            ctypes.c_void_p,
            ctypes.c_ulong,
            ctypes.c_ulong,
            ctypes.c_int,
            ctypes.c_int,
            ctypes.POINTER(ctypes.c_int),
            ctypes.POINTER(ctypes.c_int),
            ctypes.POINTER(ctypes.c_ulong),
        ]
        self.lib.XQueryTree.argtypes = [
            ctypes.c_void_p,
            ctypes.c_ulong,
            ctypes.POINTER(ctypes.c_ulong),
            ctypes.POINTER(ctypes.c_ulong),
            ctypes.POINTER(ctypes.POINTER(ctypes.c_ulong)),
            ctypes.POINTER(ctypes.c_uint),
        ]
        self.lib.XFree.argtypes = [ctypes.c_void_p]
        self.lib.XSelectInput.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_long]
        self.lib.XSync.argtypes = [ctypes.c_void_p, ctypes.c_int]
        self.lib.XPending.argtypes = [ctypes.c_void_p]
        self.lib.XPending.restype = ctypes.c_int
        self.lib.XNextEvent.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
        self.lib.XConnectionNumber.argtypes = [ctypes.c_void_p]
        self.lib.XConnectionNumber.restype = ctypes.c_int
        self.lib.XQueryPointer.argtypes = [
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
        self.lib.XCloseDisplay.argtypes = [ctypes.c_void_p]
        self.display = self.lib.XOpenDisplay(display_name.encode())
        if not self.display:
            raise RuntimeError(f"could not open X display {display_name}")
        self.root = int(self.lib.XDefaultRootWindow(self.display))

    def geometry(self, window: int) -> tuple[int, int, int, int]:
        root = ctypes.c_ulong()
        local_x = ctypes.c_int()
        local_y = ctypes.c_int()
        width = ctypes.c_uint()
        height = ctypes.c_uint()
        border = ctypes.c_uint()
        depth = ctypes.c_uint()
        if not self.lib.XGetGeometry(
            self.display,
            window,
            ctypes.byref(root),
            ctypes.byref(local_x),
            ctypes.byref(local_y),
            ctypes.byref(width),
            ctypes.byref(height),
            ctypes.byref(border),
            ctypes.byref(depth),
        ):
            raise RuntimeError(f"XGetGeometry failed for {window}")
        absolute_x = ctypes.c_int()
        absolute_y = ctypes.c_int()
        child = ctypes.c_ulong()
        if not self.lib.XTranslateCoordinates(
            self.display,
            window,
            self.root,
            0,
            0,
            ctypes.byref(absolute_x),
            ctypes.byref(absolute_y),
            ctypes.byref(child),
        ):
            raise RuntimeError(f"XTranslateCoordinates failed for {window}")
        return absolute_x.value, absolute_y.value, width.value, height.value

    def parent(self, window: int) -> int:
        root = ctypes.c_ulong()
        parent = ctypes.c_ulong()
        children = ctypes.POINTER(ctypes.c_ulong)()
        count = ctypes.c_uint()
        if not self.lib.XQueryTree(
            self.display,
            window,
            ctypes.byref(root),
            ctypes.byref(parent),
            ctypes.byref(children),
            ctypes.byref(count),
        ):
            raise RuntimeError(f"XQueryTree failed for {window}")
        if children:
            self.lib.XFree(children)
        return int(parent.value)

    def children(self, window: int) -> list[int]:
        root = ctypes.c_ulong()
        parent = ctypes.c_ulong()
        children = ctypes.POINTER(ctypes.c_ulong)()
        count = ctypes.c_uint()
        if not self.lib.XQueryTree(
            self.display,
            window,
            ctypes.byref(root),
            ctypes.byref(parent),
            ctypes.byref(children),
            ctypes.byref(count),
        ):
            raise RuntimeError(f"XQueryTree failed for {window}")
        result = [int(children[index]) for index in range(count.value)]
        if children:
            self.lib.XFree(children)
        return result

    def pointer(self) -> tuple[int, int, int]:
        root = ctypes.c_ulong()
        child = ctypes.c_ulong()
        root_x = ctypes.c_int()
        root_y = ctypes.c_int()
        window_x = ctypes.c_int()
        window_y = ctypes.c_int()
        state = ctypes.c_uint()
        if not self.lib.XQueryPointer(
            self.display,
            self.root,
            ctypes.byref(root),
            ctypes.byref(child),
            ctypes.byref(root_x),
            ctypes.byref(root_y),
            ctypes.byref(window_x),
            ctypes.byref(window_y),
            ctypes.byref(state),
        ):
            raise RuntimeError("XQueryPointer failed")
        return root_x.value, root_y.value, state.value

    def select_events(self, window: int, mask: int) -> None:
        self.lib.XSelectInput(self.display, window, mask)
        self.lib.XSync(self.display, 0)

    def _next_event(self, deadline: float) -> ctypes.Array[ctypes.c_char]:
        while self.lib.XPending(self.display) == 0:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("independent X11 event timed out")
            select.select([self.lib.XConnectionNumber(self.display)], [], [], remaining)
        event = ctypes.create_string_buffer(192)
        self.lib.XNextEvent(self.display, event)
        return event

    def wait_button_pair(self, window: int, button: int) -> tuple[_XButtonEvent, _XButtonEvent]:
        deadline = time.monotonic() + 2.0
        observed: dict[int, _XButtonEvent] = {}
        while BUTTON_PRESS not in observed or BUTTON_RELEASE not in observed:
            raw = self._next_event(deadline)
            event = _XButtonEvent.from_buffer_copy(raw)
            if event.type in {BUTTON_PRESS, BUTTON_RELEASE} and event.window == window:
                assert event.button == button
                observed[event.type] = event
        return observed[BUTTON_PRESS], observed[BUTTON_RELEASE]

    def wait_synthetic_configure(self, window: int) -> _XConfigureEvent:
        deadline = time.monotonic() + 2.0
        while True:
            raw = self._next_event(deadline)
            event = _XConfigureEvent.from_buffer_copy(raw)
            if event.type == CONFIGURE_NOTIFY and event.window == window and event.send_event:
                return event

    def close(self) -> None:
        self.lib.XCloseDisplay(self.display)


def _event(host: HostProcess, expected: str, timeout: float = 2.0) -> ProbeMessage:
    deadline = time.monotonic() + timeout
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError(f"{expected} event timed out after {timeout} seconds")
        event = host.receive(timeout=remaining, timeout_name=f"host {expected}")
        if event.type == "error":
            raise AssertionError(f"native host error: {event.fields['message']}")
        if event.type == expected:
            return event


@pytest.fixture(scope="module")
def xvfb() -> Iterator[str]:
    xvfb_binary = shutil.which("Xvfb")
    xdpyinfo = shutil.which("xdpyinfo")
    if xvfb_binary is None:
        pytest.skip("missing native prerequisite: Xvfb")
    if xdpyinfo is None:
        pytest.skip("missing native prerequisite: xdpyinfo")
    display_number = next(
        (
            number
            for number in range(90, 200)
            if not Path(f"/tmp/.X11-unix/X{number}").exists()
            and not Path(f"/tmp/.X{number}-lock").exists()
        ),
        None,
    )
    if display_number is None:
        pytest.fail("no free X11 display number")
    display = f":{display_number}"
    process = subprocess.Popen(
        [
            xvfb_binary,
            display,
            "-screen",
            "0",
            "1280x800x24",
            "-nolisten",
            "tcp",
            "-extension",
            "GLX",
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
    deadline = time.monotonic() + 3.0
    while time.monotonic() < deadline:
        if process.poll() is not None:
            stderr = process.stderr.read().decode(errors="replace")
            pytest.fail(f"Xvfb exited with {process.returncode}: {stderr}")
        ready = subprocess.run(
            [xdpyinfo, "-display", display],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        if ready.returncode == 0:
            break
        threading.Event().wait(0.01)
    else:
        os.killpg(process.pid, signal.SIGKILL)
        pytest.fail("Xvfb readiness timed out after 3 seconds")
    try:
        yield display
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=1.0)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=1.0)
        process.stderr.close()


@pytest.mark.parametrize(
    ("hierarchy", "nested"),
    [("flat", False), ("nested", True), ("synthetic-absolute", True)],
)
def test_no_plugin_geometry_matches_independent_x11(
    xvfb: str, hierarchy: str, nested: bool
) -> None:
    if not HOST.is_file():
        pytest.fail(f"native host has not been built: {HOST}")
    env = {"DISPLAY": xvfb}
    host = HostProcess(
        [str(HOST), "--no-plugin", "--hierarchy", hierarchy],
        TOKEN,
        env=env,
    )
    x11 = _X11(xvfb)
    with host:
        assert _event(host, "ready").fields["mode"] == hierarchy
        host.send({"type": "open"})
        gui = _event(host, "gui_opened")
        window = int(gui.fields["hwnd"])
        host.send({"type": "place", "x": 317, "y": 211, "w": 320, "h": 200})
        geometry = _event(host, "geometry")
        assert geometry.fields["configure_observed"] is True
        expected = (317, 211, 320, 200)
        assert (
            geometry.fields["x"],
            geometry.fields["y"],
            geometry.fields["w"],
            geometry.fields["h"],
        ) == expected
        assert x11.geometry(window) == expected
        assert (x11.parent(window) != x11.root) is nested
        host.send({"type": "place", "x": 317, "y": 211, "w": 320, "h": 200})
        repeated_place = _event(host, "geometry")
        assert repeated_place.fields["configure_observed"] is False

        host.send({"type": "resize", "w": 401, "h": 233})
        resized = _event(host, "geometry")
        assert resized.fields["w"] == 401
        assert resized.fields["configure_observed"] is True
        assert x11.geometry(window) == (317, 211, 401, 233)
        host.send({"type": "resize", "w": 401, "h": 233})
        repeated_resize = _event(host, "geometry")
        assert repeated_resize.fields["configure_observed"] is False

        if hierarchy == "synthetic-absolute":
            synthetic_target = int(gui.fields["clap_parent"])
            x11.select_events(synthetic_target, STRUCTURE_NOTIFY_MASK)
            host.send(
                {"type": "synthetic_configure", "x": 503, "y": 287, "w": 401, "h": 233}
            )
            synthetic = _event(host, "geometry")
            assert (synthetic.fields["x"], synthetic.fields["y"]) == (503, 287)
            assert synthetic.fields["synthetic_send_event"] is True
            assert (synthetic.fields["event_x"], synthetic.fields["event_y"]) == (503, 287)
            observed_configure = x11.wait_synthetic_configure(synthetic_target)
            assert observed_configure.send_event
            assert observed_configure.window == synthetic_target
            assert (observed_configure.x, observed_configure.y) == (503, 287)
            assert x11.geometry(window) == (503, 287, 401, 233)
            host.send(
                {"type": "synthetic_configure", "x": 503, "y": 287, "w": 401, "h": 233}
            )
            repeated_synthetic = _event(host, "geometry")
            assert repeated_synthetic.fields["synthetic_send_event"] is True
            x11.wait_synthetic_configure(synthetic_target)
            host.send({"type": "geometry"})
            queried = _event(host, "geometry")
            assert queried.fields["configure_observed"] is False
            assert "synthetic_send_event" not in queried.fields

        host.send({"type": "warp", "x": 601, "y": 359})
        warped = _event(host, "warped")
        assert (warped.fields["x"], warped.fields["y"]) == (601, 359)
        assert x11.pointer()[:2] == (601, 359)
        host.send({"type": "button", "x": 601, "y": 359, "button": 1})
        button_event = _event(host, "warped")
        assert button_event.fields["button"] == 1
        assert button_event.fields["press_observed"] is True
        assert button_event.fields["release_observed"] is True
        assert button_event.fields["press_state"] & (1 << 8)
        assert not button_event.fields["release_state"] & (1 << 8)
        assert (button_event.fields["x"], button_event.fields["y"]) == x11.pointer()[:2]
        host.send({"type": "close"})
    x11.close()


def _raw_host(xvfb: str) -> subprocess.Popen[bytes]:
    env = {**os.environ, "DISPLAY": xvfb, "YABRIDGE_PROBE_TOKEN": TOKEN}
    process = subprocess.Popen(
        [str(HOST), "--no-plugin"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
    )
    assert process.stdin is not None
    assert process.stdout is not None
    assert process.stderr is not None
    ready = json.loads(process.stdout.readline())
    assert ready["type"] == "ready"
    return process


@pytest.mark.parametrize(
    ("lines", "message"),
    [
        ([b'{"v":1,"seq":0,"type":"close","token":"wrong"}\n'], "token"),
        (
            [
                b'{"v":1,"seq":0,"type":"open","token":"native-host-secret"}\n',
                b'{"v":1,"seq":0,"type":"close","token":"native-host-secret"}\n',
            ],
            "duplicate",
        ),
        (
            [b'{"v":1,"seq":2,"type":"close","token":"native-host-secret"}\n'],
            "out-of-order",
        ),
        (
            [b'{"v":2,"seq":0,"type":"close","token":"native-host-secret"}\n'],
            "version",
        ),
        ([b"\xff\n"], "UTF-8"),
        ([b"x" * MAX_LINE_BYTES + b"\n"], "64 KiB"),
        (
            [b'{"v":1,"seq":0,"type":"close","token":"native-host-secret"} garbage\n'],
            "JSON",
        ),
        (
            [b'{"v":1,"seq":0,"type":"unknown","token":"native-host-secret"}\n'],
            "unrecognized",
        ),
    ],
)
def test_real_binary_rejects_invalid_protocol(
    xvfb: str, lines: list[bytes], message: str
) -> None:
    process = _raw_host(xvfb)
    assert process.stdin is not None
    assert process.stdout is not None
    for line in lines:
        process.stdin.write(line)
        process.stdin.flush()
    process.stdin.close()
    events = []
    while True:
        line = process.stdout.readline()
        if not line:
            break
        events.append(json.loads(line))
    process.stderr.read()
    assert process.wait(timeout=2.0) != 0
    process.stdout.close()
    process.stderr.close()
    assert any(event["type"] == "error" and message in event["message"] for event in events)


def test_real_binary_accepts_exact_64k_line(xvfb: str) -> None:
    process = _raw_host(xvfb)
    assert process.stdin is not None
    payload = b'{"v":1,"seq":0,"type":"close","token":"native-host-secret"}'
    line = payload + b" " * (MAX_LINE_BYTES - len(payload) - 1) + b"\n"
    assert len(line) == MAX_LINE_BYTES
    process.stdin.write(line)
    process.stdin.flush()
    process.stdin.close()
    assert process.wait(timeout=2.0) == 0
    assert process.stdout is not None
    assert process.stderr is not None
    process.stdout.read()
    process.stderr.read()
    process.stdout.close()
    process.stderr.close()


def test_plugin_fixture_preserves_wrapper_and_wine_identity(xvfb: str) -> None:
    if not FIXTURE.is_file():
        pytest.fail(f"native CLAP fixture has not been built: {FIXTURE}")
    host = HostProcess(
        [str(HOST), "--plugin", str(FIXTURE)],
        TOKEN,
        env={"DISPLAY": xvfb},
    )
    x11 = _X11(xvfb)
    with host:
        _event(host, "ready")
        host.send({"type": "open"})
        gui = _event(host, "gui_opened")
        parent = int(gui.fields["clap_parent"])
        wrapper = int(gui.fields["wrapper"])
        wine = int(gui.fields["wine_window"])
        assert parent != x11.root
        assert x11.parent(parent) == x11.root
        assert x11.parent(wrapper) == parent
        assert x11.parent(wine) == wrapper
        internal = x11.children(wine)
        assert len(internal) == 1
        assert int(gui.fields["hwnd"]) == wine
        assert int(gui.fields["hwnd"]) != internal[0]
        callback = _event(host, "clap")
        if callback.fields["event"] == "gui_shown":
            callback = _event(host, "clap")
        assert callback.fields["event"] == "callback"
        assert callback.fields["main_thread"] is True
        host.send({"type": "button", "x": 100, "y": 100, "button": 1})
        button = _event(host, "warped")
        assert button.fields["press_observed"] is True
        assert button.fields["release_observed"] is True
        host.send({"type": "close"})
    x11.close()


def test_synthetic_absolute_targets_host_parent_without_moving_bridge_windows(
    xvfb: str,
) -> None:
    host = HostProcess(
        [
            str(HOST),
            "--plugin",
            str(FIXTURE),
            "--hierarchy",
            "synthetic-absolute",
        ],
        TOKEN,
        env={"DISPLAY": xvfb},
    )
    x11 = _X11(xvfb)
    with host:
        _event(host, "ready")
        host.send({"type": "open"})
        opened = _event(host, "gui_opened")
        outer = int(opened.fields["outer"])
        intermediate = int(opened.fields["intermediate"])
        parent = int(opened.fields["clap_parent"])
        wrapper = int(opened.fields["wrapper"])
        wine = int(opened.fields["wine_window"])
        assert x11.parent(outer) == x11.root
        assert x11.parent(intermediate) == outer
        assert x11.parent(parent) == intermediate
        assert x11.parent(wrapper) == parent
        assert x11.parent(wine) == wrapper
        assert (
            int(opened.fields["hierarchy_offset_x"]),
            int(opened.fields["hierarchy_offset_y"]),
        ) == (56, 64)

        host.send({"type": "place", "x": 503, "y": 287, "w": 320, "h": 200})
        _event(host, "geometry")
        placed_x11 = _event(host, "x11")
        assert (placed_x11.fields["x"], placed_x11.fields["y"]) == (503, 287)
        assert x11.geometry(parent)[:2] == x11.geometry(wrapper)[:2]
        assert x11.geometry(wrapper)[:2] == x11.geometry(wine)[:2]

        host.send(
            {"type": "synthetic_configure", "x": 503, "y": 287, "w": 320, "h": 200}
        )
        synthetic = _event(host, "geometry")
        synthetic_x11 = _event(host, "x11")
        assert synthetic.fields["synthetic_send_event"] is True
        assert synthetic.fields["synthetic_window"] == parent
        assert (synthetic.fields["event_x"], synthetic.fields["event_y"]) == (503, 287)
        assert (synthetic_x11.fields["parent_x"], synthetic_x11.fields["parent_y"]) == (
            0,
            0,
        )
        assert (synthetic.fields["event_x"], synthetic.fields["event_y"]) != (
            synthetic_x11.fields["parent_x"],
            synthetic_x11.fields["parent_y"],
        )
        host.send({"type": "close"})
    x11.close()


def test_plugin_fixture_rejects_ambiguous_direct_children(xvfb: str) -> None:
    host = HostProcess(
        [str(HOST), "--plugin", str(FIXTURE)],
        TOKEN,
        env={"DISPLAY": xvfb, "YABRIDGE_FIXTURE_AMBIGUOUS": "1"},
    )
    with host:
        _event(host, "ready")
        host.send({"type": "open"})
        with pytest.raises(AssertionError, match="ambiguous plugin window chain"):
            _event(host, "gui_opened", timeout=3.0)


def test_plugin_fixture_delayed_children_are_discovered_promptly(xvfb: str) -> None:
    host = HostProcess(
        [str(HOST), "--plugin", str(FIXTURE)],
        TOKEN,
        env={"DISPLAY": xvfb, "YABRIDGE_FIXTURE_DELAY_CHILDREN": "1"},
    )
    with host:
        _event(host, "ready")
        started = time.monotonic()
        host.send({"type": "open"})
        _event(host, "gui_opened")
        elapsed = time.monotonic() - started
        assert 0.05 <= elapsed < 1.0
        host.send({"type": "close"})


def test_plugin_resize_reports_observed_adjusted_geometry(xvfb: str) -> None:
    host = HostProcess(
        [str(HOST), "--plugin", str(FIXTURE)],
        TOKEN,
        env={"DISPLAY": xvfb, "YABRIDGE_FIXTURE_ADJUST": "1"},
    )
    with host:
        _event(host, "ready")
        host.send({"type": "open"})
        opened = _event(host, "gui_opened")
        container = int(opened.fields["clap_parent"])
        host.send({"type": "place", "x": 101, "y": 83, "w": 320, "h": 200})
        _event(host, "geometry")
        host.send({"type": "resize", "w": 400, "h": 230})
        resized = _event(host, "geometry")
        assert resized.fields["configure_observed"] is True
        assert (resized.fields["w"], resized.fields["h"]) == (407, 239)
        x11 = _X11(xvfb)
        assert x11.geometry(container)[2:] == (407, 239)
        x11.close()
        host.send({"type": "resize", "w": 400, "h": 230})
        repeated = _event(host, "geometry")
        assert (repeated.fields["w"], repeated.fields["h"]) == (407, 239)
        assert repeated.fields["configure_observed"] is False
        host.send({"type": "close"})


def test_plugin_async_resize_waits_for_accepted_geometry(xvfb: str) -> None:
    host = HostProcess(
        [str(HOST), "--plugin", str(FIXTURE)],
        TOKEN,
        env={
            "DISPLAY": xvfb,
            "YABRIDGE_FIXTURE_ADJUST": "1",
            "YABRIDGE_FIXTURE_ASYNC_RESIZE": "1",
        },
    )
    x11 = _X11(xvfb)
    with host:
        _event(host, "ready")
        host.send({"type": "open"})
        opened = _event(host, "gui_opened")
        container = int(opened.fields["clap_parent"])
        wine = int(opened.fields["wine_window"])
        host.send({"type": "place", "x": 101, "y": 83, "w": 320, "h": 200})
        _event(host, "geometry")

        started = time.monotonic()
        host.send({"type": "resize", "w": 400, "h": 230})
        resized = _event(host, "geometry")
        elapsed = time.monotonic() - started
        assert 0.1 <= elapsed < 1.0
        assert resized.fields["configure_observed"] is True
        assert (resized.fields["w"], resized.fields["h"]) == (407, 239)
        assert x11.geometry(wine)[2:] == (407, 239)
        assert x11.geometry(container)[2:] == (407, 239)

        started = time.monotonic()
        host.send({"type": "resize", "w": 400, "h": 230})
        repeated = _event(host, "geometry")
        assert time.monotonic() - started < 0.1
        assert repeated.fields["configure_observed"] is False
        assert (repeated.fields["w"], repeated.fields["h"]) == (407, 239)
        assert x11.geometry(container)[2:] == (407, 239)
        host.send({"type": "close"})
    x11.close()
