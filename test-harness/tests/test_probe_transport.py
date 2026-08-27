"""Transport boundary tests for coordinate probe sessions."""

from __future__ import annotations

import io
import json
import os
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path
from typing import BinaryIO

import pytest

from yabridge_test.probe.protocol import MAX_LINE_BYTES, ProtocolError
from yabridge_test.probe.transport import HostProcess, PluginListener, TransportError

TOKEN = "transport-secret"


def _message(seq: int, message_type: str = "ready", **fields: object) -> bytes:
    payload = {"v": 1, "seq": seq, "type": message_type, "token": TOKEN, **fields}
    return (json.dumps(payload, separators=(",", ":")) + "\n").encode()


def _listener_pair(*, queue_size: int = 4) -> tuple[PluginListener, socket.socket]:
    reader, writer = socket.socketpair()
    listener = PluginListener.from_socket(reader, TOKEN, queue_size=queue_size)
    listener.start()
    return listener, writer


@pytest.mark.parametrize(
    ("lines", "match"),
    [
        (
            [
                b'{"v":1,"seq":0,"type":"ready","token":"wrong"}\n',
            ],
            "invalid authentication token",
        ),
        ([_message(0), _message(0)], "duplicate sequence number"),
        ([_message(0), _message(2)], "out-of-order sequence number"),
        ([b"\xff\n"], "invalid UTF-8"),
        ([b"x" * (MAX_LINE_BYTES + 1)], "line exceeds 64 KiB limit"),
        ([b'{"v":1,"seq":0,"type":"ready","token":"transport-secret"'], "truncated"),
    ],
)
def test_plugin_listener_fails_session_on_protocol_error(
    lines: list[bytes], match: str
) -> None:
    listener, writer = _listener_pair()
    with listener, writer:
        for line in lines:
            writer.sendall(line)
        writer.shutdown(socket.SHUT_WR)
        if len(lines) > 1:
            assert listener.receive(timeout=0.5, timeout_name="first plugin event").seq == 0
        with pytest.raises(ProtocolError, match=match):
            listener.receive(timeout=0.5, timeout_name="invalid plugin event")


def test_plugin_listener_timeout_is_named() -> None:
    listener, writer = _listener_pair()
    with listener, writer:
        with pytest.raises(TimeoutError, match="plugin hello.*0.05"):
            listener.receive(timeout=0.05, timeout_name="plugin hello")


def test_plugin_listener_binds_numeric_loopback_with_random_token() -> None:
    listener = PluginListener(accept_timeout=0.5)
    address, port_text = listener.endpoint.split(":")
    assert address == "127.0.0.1"
    assert int(port_text) > 0
    assert len(listener.token) >= 32
    with listener, socket.create_connection((address, int(port_text)), timeout=0.5) as writer:
        payload = {
            "v": 1,
            "seq": 0,
            "type": "ready",
            "token": listener.token,
        }
        writer.sendall((json.dumps(payload) + "\n").encode())
        assert listener.receive(timeout=0.5, timeout_name="plugin ready").type == "ready"


def test_plugin_listener_default_accepts_bounded_cold_start_without_sleep() -> None:
    listener = PluginListener()
    assert listener._accept_timeout >= 30.0
    entered_receive = threading.Event()
    finished = threading.Event()
    received: list[str] = []

    def receive() -> None:
        entered_receive.set()
        received.append(
            listener.receive(timeout=1.0, timeout_name="cold Wine plugin hello").type
        )
        finished.set()

    thread = threading.Thread(target=receive)
    thread.start()
    assert entered_receive.wait(timeout=0.5)
    address, port_text = listener.endpoint.split(":")
    with socket.create_connection((address, int(port_text)), timeout=0.5) as writer:
        writer.sendall(
            (
                json.dumps(
                    {
                        "v": 1,
                        "seq": 0,
                        "type": "hello",
                        "token": listener.token,
                        "plugin_id": "org.yabridge.coordprobe",
                    }
                )
                + "\n"
            ).encode()
        )
        assert finished.wait(timeout=0.5)
    thread.join(timeout=0.5)
    listener.close()
    assert received == ["hello"]


def test_plugin_listener_applies_bounded_queue_backpressure() -> None:
    listener, writer = _listener_pair(queue_size=1)
    with listener, writer:
        writer.sendall(_message(0) + _message(1) + _message(2))
        assert listener.pending_count <= 1
        assert listener.receive(timeout=0.5, timeout_name="event zero").seq == 0
        assert listener.receive(timeout=0.5, timeout_name="event one").seq == 1
        assert listener.receive(timeout=0.5, timeout_name="event two").seq == 2


def test_plugin_listener_sends_structured_json_commands() -> None:
    listener, peer = _listener_pair()
    with listener, peer:
        listener.send({"type": "mark", "label": 'quote"\nnewline'})
        line = peer.makefile("rb").readline()
    assert json.loads(line) == {
        "v": 1,
        "seq": 0,
        "type": "mark",
        "token": TOKEN,
        "label": 'quote"\nnewline',
    }


class _FakeProcess:
    def __init__(self, stdout: BinaryIO, stderr: BinaryIO, returncode: int | None = None) -> None:
        self.stdout = stdout
        self.stderr = stderr
        self.stdin = io.BytesIO()
        self.returncode = returncode
        self.pid = 987654
        self.terminate_calls = 0
        self.kill_calls = 0

    def poll(self) -> int | None:
        return self.returncode

    def wait(self, timeout: float | None = None) -> int:
        if self.returncode is None:
            raise subprocess.TimeoutExpired("fake", timeout)
        return self.returncode

    def terminate_group(self) -> None:
        self.terminate_calls += 1
        self.returncode = 0

    def kill_group(self) -> None:
        self.kill_calls += 1
        self.returncode = -signal.SIGKILL


def test_host_process_decodes_stdout_but_not_stderr_as_protocol() -> None:
    process = _FakeProcess(
        io.BytesIO(_message(0)),
        io.BytesIO(b'{"v":1,"seq":999,"type":"ready","token":"wrong"}\nwarning\n'),
        returncode=0,
    )
    host = HostProcess.from_process(process, TOKEN)
    with host:
        assert host.receive(timeout=0.5, timeout_name="host ready").type == "ready"
    assert "warning" in host.stderr_tail


def test_host_process_timeout_is_named() -> None:
    reader_socket, writer_socket = socket.socketpair()
    process = _FakeProcess(
        reader_socket.makefile("rb"),
        io.BytesIO(b"native host is waiting\n"),
        returncode=None,
    )
    host = HostProcess.from_process(process, TOKEN)
    try:
        with pytest.raises(TimeoutError, match="native ready.*0.05.*native host is waiting"):
            host.receive(timeout=0.05, timeout_name="native ready")
    finally:
        writer_socket.close()
        host.close()
        reader_socket.close()


@pytest.mark.parametrize(
    ("stdout", "match"),
    [
        (
            b'{"v":1,"seq":0,"type":"ready","token":"wrong"}\n',
            "invalid authentication token",
        ),
        (_message(0) + _message(0), "duplicate sequence number"),
        (_message(0) + _message(2), "out-of-order sequence number"),
        (b"x" * (MAX_LINE_BYTES + 1), "line exceeds 64 KiB limit"),
        (b'{"v":1,"seq":0,"type":"ready","token":"transport-secret"', "truncated"),
    ],
)
def test_host_process_fails_on_invalid_stdout(stdout: bytes, match: str) -> None:
    process = _FakeProcess(io.BytesIO(stdout), io.BytesIO(), returncode=7)
    host = HostProcess.from_process(process, TOKEN)
    with host:
        if stdout.startswith(_message(0)):
            assert host.receive(timeout=0.5, timeout_name="first host event").seq == 0
        with pytest.raises(ProtocolError, match=match):
            host.receive(timeout=0.5, timeout_name="invalid host event")


def test_host_process_applies_bounded_queue_backpressure() -> None:
    process = _FakeProcess(
        io.BytesIO(_message(0) + _message(1) + _message(2)),
        io.BytesIO(),
        returncode=0,
    )
    host = HostProcess.from_process(process, TOKEN, queue_size=1)
    with host:
        assert host.pending_count <= 1
        assert [host.receive(timeout=0.5, timeout_name="host event").seq for _ in range(3)] == [
            0,
            1,
            2,
        ]


def test_host_process_reports_death_with_bounded_stderr_tail() -> None:
    stderr = b"x" * 20000 + b"\nfatal native error\n"
    process = _FakeProcess(io.BytesIO(), io.BytesIO(stderr), returncode=23)
    host = HostProcess.from_process(process, TOKEN, stderr_limit=4096)
    with host:
        with pytest.raises(TransportError, match=r"(?s)exited with status 23.*fatal native error"):
            host.receive(timeout=0.5, timeout_name="host ready")
    assert len(host.stderr_tail.encode()) <= 4096


def test_host_process_sends_json_without_interpolation() -> None:
    process = _FakeProcess(io.BytesIO(), io.BytesIO(), returncode=0)
    host = HostProcess.from_process(process, TOKEN)
    with host:
        host.send({"type": "mark", "label": 'quote"\nnewline'})
        line = process.stdin.getvalue()
    decoded = json.loads(line)
    assert decoded == {
        "v": 1,
        "seq": 0,
        "type": "mark",
        "token": TOKEN,
        "label": 'quote"\nnewline',
    }
    assert line.endswith(b"\n")


def test_host_process_send_has_named_deadline_and_stderr() -> None:
    reader_fd, writer_fd = os.pipe()
    os.set_blocking(writer_fd, False)
    while True:
        try:
            os.write(writer_fd, b"x" * 4096)
        except BlockingIOError:
            break
    os.set_blocking(writer_fd, True)
    process = _FakeProcess(io.BytesIO(), io.BytesIO(b"blocked host stdin\n"), returncode=None)
    process.stdin = os.fdopen(writer_fd, "wb", buffering=0)
    host = HostProcess.from_process(process, TOKEN, close_timeout=0.01)
    try:
        with pytest.raises(TimeoutError, match="host command.*0.05.*blocked host stdin"):
            host.send(
                {"type": "mark", "label": "blocked"},
                timeout=0.05,
                timeout_name="host command",
            )
    finally:
        host.close()
        os.close(reader_fd)


def test_host_process_send_reports_epipe_with_stderr() -> None:
    reader_fd, writer_fd = os.pipe()
    os.close(reader_fd)
    process = _FakeProcess(
        io.BytesIO(), io.BytesIO(b"host rejected stdin\n"), returncode=9
    )
    process.stdin = os.fdopen(writer_fd, "wb", buffering=0)
    host = HostProcess.from_process(process, TOKEN)
    with host:
        with pytest.raises(
            TransportError, match="command write failed.*host rejected stdin"
        ):
            host.send({"type": "close"})


def test_host_process_close_is_idempotent_and_terminates_group() -> None:
    process = _FakeProcess(io.BytesIO(), io.BytesIO(), returncode=None)
    host = HostProcess.from_process(process, TOKEN, close_timeout=0.01)
    host.close()
    host.close()
    assert process.terminate_calls == 1
    assert process.kill_calls == 0


def test_real_host_process_uses_new_session_and_kills_descendants() -> None:
    script = (
        "import os,subprocess,time;"
        f"subprocess.Popen([{sys.executable!r},'-c','import time; time.sleep(30)']);"
        "print(os.getpid(),flush=True);time.sleep(30)"
    )
    host = HostProcess(
        [sys.executable, "-c", script],
        TOKEN,
        close_timeout=0.2,
    )
    pid = host.pid
    assert os.getsid(pid) == pid
    host.close()
    deadline = time.monotonic() + 1.0
    while time.monotonic() < deadline:
        try:
            os.killpg(pid, 0)
        except ProcessLookupError:
            break
        threading.Event().wait(0.01)
    else:
        pytest.fail("host process group survived close")


def test_host_process_kills_group_after_leader_already_exited(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    with tempfile.TemporaryDirectory() as directory:
        child_path = os.path.join(directory, "child.pid")
        script = (
            "import pathlib,subprocess,sys;"
            "child=subprocess.Popen([sys.executable,'-c','import time;time.sleep(3)']);"
            f"pathlib.Path({child_path!r}).write_text(str(child.pid))"
        )
        host = HostProcess([sys.executable, "-c", script], TOKEN, close_timeout=0.2)
        deadline = time.monotonic() + 2.0
        while not os.path.exists(child_path):
            if time.monotonic() >= deadline:
                pytest.fail("leader did not publish descendant pid")
            threading.Event().wait(0.01)
        child_pid = int(Path(child_path).read_text(encoding="utf-8"))
        deadline = time.monotonic() + 2.0
        while host._process.poll() is None:
            if time.monotonic() >= deadline:
                pytest.fail("leader did not exit")
            threading.Event().wait(0.01)
        killpg_calls: list[tuple[int, int]] = []

        def reject_recycled_group_signal(pgid: int, sig: int) -> None:
            killpg_calls.append((pgid, sig))
            raise AssertionError("killpg called after process-group leader was reaped")

        monkeypatch.setattr(os, "killpg", reject_recycled_group_signal)
        close_started = time.monotonic()
        host.close()
        assert time.monotonic() - close_started < 0.8
        assert killpg_calls == []
        deadline = time.monotonic() + 1.0
        while time.monotonic() < deadline:
            try:
                os.kill(child_pid, 0)
            except ProcessLookupError:
                break
            threading.Event().wait(0.01)
        else:
            pytest.fail("descendant survived after its process-group leader exited")
