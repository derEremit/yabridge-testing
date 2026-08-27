"""Pure-Wine integration baseline for the coordinate probe."""

from __future__ import annotations

import ctypes
import json
import os
import secrets
import shutil
import socket
import subprocess
import time
from pathlib import Path
from typing import Any

import pytest

from yabridge_test.probe.protocol import ProtocolValidator, decode_message

REPO_ROOT = Path(__file__).resolve().parents[2]
PROBE_ROOT = REPO_ROOT / "probe"
CROSS_FILE = PROBE_ROOT / "cross" / "mingw-w64-x86_64.ini"


def _require(name: str) -> str:
    executable = shutil.which(name)
    if executable is None:
        pytest.skip(f"missing prerequisite: {name}")
    return executable


def _require_x11() -> None:
    try:
        ctypes.CDLL("libX11.so.6")
    except OSError:
        pytest.skip("missing prerequisite: libX11.so.6")


def _build(build_dir: Path) -> tuple[Path, Path, Path]:
    subprocess.run(
        ["meson", "setup", "--cross-file", str(CROSS_FILE), str(build_dir), str(PROBE_ROOT)],
        cwd=REPO_ROOT,
        check=True,
        timeout=120,
    )
    subprocess.run(
        ["meson", "compile", "-C", str(build_dir)],
        cwd=REPO_ROOT,
        check=True,
        timeout=120,
    )
    return (
        build_dir / "coordprobe.clap-win",
        build_dir / "coordprobe-test.clap-win",
        build_dir / "coordprobe-selftest.exe",
    )


def _encode_commands(token: str) -> list[bytes]:
    payloads: list[dict[str, object]] = [
        {"v": 1, "seq": 0, "type": "mark", "token": token, "label": "baseline"},
        {"v": 1, "seq": 1, "type": "origin", "token": token, "x": 0, "y": 0},
    ]
    lines = [
        (json.dumps(payload, separators=(",", ":")) + "\n").encode() for payload in payloads
    ]
    validator = ProtocolValidator(token)
    for line in lines:
        validator.validate(decode_message(line))
    return lines


def test_baseline_commands_are_strict_valid_protocol() -> None:
    """Malformed command framing must be caught before any socket write."""
    token = "unit-test-token"
    lines = _encode_commands(token)
    validator = ProtocolValidator(token)
    decoded = []
    for line in lines:
        assert json.loads(line) == json.loads(line.decode("utf-8"))
        message = decode_message(line)
        validator.validate(message)
        decoded.append(message)
    assert [(message.type, message.seq) for message in decoded] == [
        ("mark", 0),
        ("origin", 1),
    ]


def _start_xvfb(tmp_path: Path) -> tuple[subprocess.Popen[bytes], str]:
    xvfb = _require("Xvfb")
    xdpyinfo = _require("xdpyinfo")
    for display_number in range(120, 180):
        display = f":{display_number}"
        process = subprocess.Popen(
            [
                xvfb,
                display,
                "-screen",
                "0",
                "1024x768x24",
                "-nolisten",
                "tcp",
                "-extension",
                "GLX",
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env={
                **os.environ,
                "LIBGL_ALWAYS_SOFTWARE": "1",
                "__GLX_VENDOR_LIBRARY_NAME": "mesa",
            },
        )
        env = {**os.environ, "DISPLAY": display, "XAUTHORITY": str(tmp_path / "xauthority")}
        for _ in range(40):
            if process.poll() is not None:
                break
            check = subprocess.run(
                [xdpyinfo],
                env=env,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )
            if check.returncode == 0:
                time.sleep(0.05)
                if process.poll() is None:
                    return process, display
            time.sleep(0.05)
        process.terminate()
        process.wait(timeout=2)
    pytest.fail("Xvfb prerequisite present but no temporary display could be started")


def _warp_pointer(display_name: str, x: int, y: int) -> None:
    try:
        x11 = ctypes.CDLL("libX11.so.6")
    except OSError:
        pytest.fail("libX11.so.6 disappeared after prerequisite check")
    x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
    x11.XOpenDisplay.restype = ctypes.c_void_p
    x11.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
    x11.XDefaultRootWindow.restype = ctypes.c_ulong
    x11.XWarpPointer.argtypes = [
        ctypes.c_void_p,
        ctypes.c_ulong,
        ctypes.c_ulong,
        ctypes.c_int,
        ctypes.c_int,
        ctypes.c_uint,
        ctypes.c_uint,
        ctypes.c_int,
        ctypes.c_int,
    ]
    x11.XFlush.argtypes = [ctypes.c_void_p]
    x11.XCloseDisplay.argtypes = [ctypes.c_void_p]
    display = x11.XOpenDisplay(display_name.encode())
    if not display:
        pytest.fail("XOpenDisplay failed after Xvfb started")
    try:
        root = x11.XDefaultRootWindow(display)
        assert x11.XWarpPointer(display, 0, root, 0, 0, 0, 0, x, y) != 0
        x11.XFlush(display)
    finally:
        x11.XCloseDisplay(display)


def _read_events(
    connection: socket.socket, token: str, display: str
) -> tuple[list[dict[str, Any]], tuple[int, int]]:
    validator = ProtocolValidator(token)
    events: list[dict[str, Any]] = []
    origin: tuple[int, int] | None = None
    attached = False
    commands_sent = False
    connection.settimeout(15)
    with connection.makefile("rb") as stream:
        while True:
            line = stream.readline(65537)
            assert line, f"probe connection closed before a mouse event; events={events!r}"
            message = decode_message(line)
            validator.validate(message)
            event = {"type": message.type, **message.fields}
            events.append(event)
            if message.type == "attached":
                attached = True
            elif message.type == "origin":
                origin = (int(message.fields["x"]), int(message.fields["y"]))
            if attached and origin is not None and not commands_sent:
                for command in _encode_commands(token):
                    connection.sendall(command)
                commands_sent = True
            mark_seen = any(
                e["type"] == "mark" and e.get("label") == "baseline" for e in events
            )
            origin_count = sum(e["type"] == "origin" for e in events)
            if origin is not None and mark_seen and origin_count >= 2 and not any(
                e["type"] == "mouse" for e in events
            ):
                _warp_pointer(display, origin[0] + 5, origin[1] + 5)
                time.sleep(0.05)
                _warp_pointer(display, origin[0] + 41, origin[1] + 29)
            if message.type == "bye" and any(e["type"] == "mouse" for e in events):
                return events, origin or (0, 0)


@pytest.mark.wine_probe
def test_pure_wine_host_reports_client_mouse_coordinates(tmp_path: Path) -> None:
    """A client/screen coordinate mixup must fail before yabridge is involved."""
    _require("meson")
    _require("x86_64-w64-mingw32-gcc")
    wine = _require("wine")
    wineboot = _require("wineboot")
    wineserver = _require("wineserver")
    _require_x11()
    plugin, test_plugin, selftest = _build(tmp_path / "build")
    assert test_plugin.is_file(), "test-hook probe artifact was not built"
    xvfb, display = _start_xvfb(tmp_path)
    token = secrets.token_hex(24)

    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        listener.settimeout(0.1)
        port = listener.getsockname()[1]
        env = {
            **os.environ,
            "DISPLAY": display,
            "WINEPREFIX": str(tmp_path / "wine-prefix"),
            "WINEARCH": "win64",
            "WINEDEBUG": "-all",
            "WINEDLLOVERRIDES": "mscoree,mshtml=",
            "LIBGL_ALWAYS_SOFTWARE": "1",
            "__GLX_VENDOR_LIBRARY_NAME": "mesa",
            "YABRIDGE_PROBE_ENDPOINT": f"127.0.0.1:{port}",
            "YABRIDGE_PROBE_TOKEN": token,
        }
        try:
            subprocess.run(
                [wineboot, "--init"],
                env=env,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=True,
                timeout=60,
            )
            subprocess.run(
                [wineserver, "-w"],
                env=env,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=True,
                timeout=30,
            )
        except BaseException:
            subprocess.run(
                [wineserver, "-k"],
                env=env,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
                timeout=10,
            )
            xvfb.terminate()
            xvfb.wait(timeout=5)
            raise
        host = subprocess.Popen(
            [wine, str(selftest), str(plugin)],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        stdout = b""
        stderr = b""
        sessions: list[tuple[list[dict[str, Any]], tuple[int, int]]] = []
        hook_host: subprocess.Popen[bytes] | None = None
        try:
            for cycle in range(2):
                deadline = time.monotonic() + 20
                while True:
                    if host.poll() is not None:
                        stdout, stderr = host.communicate()
                        pytest.fail(
                            f"Wine baseline exited before lifecycle cycle {cycle + 1}: "
                            + (stdout + stderr).decode(errors="replace")
                        )
                    try:
                        connection, _address = listener.accept()
                        break
                    except TimeoutError:
                        if time.monotonic() >= deadline:
                            pytest.fail(
                                f"Wine baseline timed out before lifecycle cycle {cycle + 1}"
                            )
                with connection:
                    try:
                        sessions.append(_read_events(connection, token, display))
                    except AssertionError as exc:
                        stdout, stderr = host.communicate(timeout=15)
                        pytest.fail(
                            f"{exc}; Wine output: "
                            + (stdout + stderr).decode(errors="replace")
                        )
            stdout, stderr = host.communicate(timeout=15)
            assert host.returncode == 0, (stdout + stderr).decode(errors="replace")

            missing_token_env = dict(env)
            missing_token_env.pop("YABRIDGE_PROBE_TOKEN")
            missing_token = subprocess.run(
                [wine, str(selftest), str(plugin)],
                env=missing_token_env,
                capture_output=True,
                check=False,
                timeout=15,
            )
            assert missing_token.returncode != 0
            assert b"coordprobe: missing YABRIDGE_PROBE_TOKEN" in missing_token.stderr

            missing_endpoint_env = dict(env)
            missing_endpoint_env.pop("YABRIDGE_PROBE_ENDPOINT")
            missing_endpoint = subprocess.run(
                [wine, str(selftest), str(plugin)],
                env=missing_endpoint_env,
                capture_output=True,
                check=False,
                timeout=15,
            )
            assert missing_endpoint.returncode != 0
            assert b"coordprobe: missing YABRIDGE_PROBE_ENDPOINT" in missing_endpoint.stderr

            oversized_endpoint = subprocess.run(
                [wine, str(selftest), str(plugin)],
                env={**env, "YABRIDGE_PROBE_ENDPOINT": "x" * 128},
                capture_output=True,
                check=False,
                timeout=15,
            )
            assert oversized_endpoint.returncode != 0
            assert (
                b"coordprobe: YABRIDGE_PROBE_ENDPOINT exceeds 127-byte limit"
                in oversized_endpoint.stderr
            )

            oversized_token = subprocess.run(
                [wine, str(selftest), str(plugin)],
                env={**env, "YABRIDGE_PROBE_TOKEN": "x" * 128},
                capture_output=True,
                check=False,
                timeout=15,
            )
            assert oversized_token.returncode != 0
            assert (
                b"coordprobe: YABRIDGE_PROBE_TOKEN exceeds 127-byte limit"
                in oversized_token.stderr
            )

            hook_host = subprocess.Popen(
                [
                    wine,
                    str(selftest),
                    str(test_plugin),
                    "--create-failure-recovery",
                ],
                env={**env, "YABRIDGE_PROBE_TEST_HOOK": "fail_create"},
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            listener.settimeout(15)
            create_connection, _address = listener.accept()
            create_stdout, create_stderr = hook_host.communicate(timeout=15)
            create_connection.close()
            assert hook_host.returncode == 0, (create_stdout + create_stderr).decode(
                errors="replace"
            )
            assert b"coordprobe: CreateThread failed with error" in create_stderr
            hook_host = None

            hook_host = subprocess.Popen(
                [wine, str(selftest), str(test_plugin)],
                env={**env, "YABRIDGE_PROBE_TEST_HOOK": "fail_send"},
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            failure_connections: list[socket.socket] = []
            for _cycle in range(2):
                connection, _address = listener.accept()
                failure_connections.append(connection)
            failure_stdout, failure_stderr = hook_host.communicate(timeout=15)
            for connection in failure_connections:
                connection.close()
            assert hook_host.returncode == 0, (
                failure_stdout + failure_stderr
            ).decode(errors="replace")
            assert (
                failure_stderr.count(
                    b"coordprobe: protocol send failed with Winsock error"
                )
                == 2
            )
            hook_host = None

            timeout_connections: list[socket.socket] = []
            hook_host = subprocess.Popen(
                [wine, str(selftest), str(test_plugin), "--timeout-restart"],
                env={**env, "YABRIDGE_PROBE_TEST_HOOK": "timeout_restart"},
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            for _cycle in range(2):
                connection, _address = listener.accept()
                timeout_connections.append(connection)
            timeout_stdout, timeout_stderr = hook_host.communicate(timeout=20)
            for connection in timeout_connections:
                connection.close()
            assert hook_host.returncode == 0, (
                timeout_stdout + timeout_stderr
            ).decode(errors="replace")
            assert (
                b"coordprobe: refusing report restart while previous worker is running"
                in timeout_stderr
            )
            assert b"coordprobe: reaped completed previous worker" in timeout_stderr
            hook_host = None
        finally:
            if hook_host is not None and hook_host.poll() is None:
                hook_host.kill()
                hook_host.wait(timeout=5)
            if hook_host is not None and hook_host.stdout is not None:
                hook_host.stdout.close()
            if hook_host is not None and hook_host.stderr is not None:
                hook_host.stderr.close()
            if host.poll() is None:
                host.terminate()
                try:
                    host.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    host.kill()
                    host.wait(timeout=5)
            if host.stdout is not None:
                host.stdout.close()
            if host.stderr is not None:
                host.stderr.close()
            subprocess.run(
                [wineserver, "-k"],
                env=env,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
                timeout=10,
            )
            xvfb.terminate()
            xvfb.wait(timeout=5)

    assert len(sessions) == 2
    for events, origin in sessions:
        assert events[0]["type"] == "hello"
        assert events[0]["plugin_id"] == "org.yabridge.coordprobe"
        assert any(event["type"] == "attached" for event in events)
        assert any(
            event["type"] == "mark" and event["label"] == "baseline" for event in events
        )
        assert events[-1]["type"] == "bye"
        mouse = next(
            event
            for event in events
            if event["type"] == "mouse"
            and abs(int(event["x"]) - 41) <= 2
            and abs(int(event["y"]) - 29) <= 2
        )
        assert (mouse["x"], mouse["y"]) == pytest.approx((41, 29), abs=2)
        assert (mouse["origin_x"], mouse["origin_y"]) == origin
        assert (mouse["screen_x"], mouse["screen_y"]) == pytest.approx(
            (origin[0] + 41, origin[1] + 29), abs=2
        )
        assert (mouse["cursor_x"], mouse["cursor_y"]) == pytest.approx(
            (origin[0] + 41, origin[1] + 29), abs=2
        )
        assert "virtual_x" in mouse
        assert "virtual_y" in mouse
