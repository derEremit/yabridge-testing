"""Bounded JSONL transports for the native host and bridged probe plugin."""

from __future__ import annotations

import json
import os
import queue
import secrets
import select
import signal
import socket
import subprocess
import threading
import time
from collections import deque
from collections.abc import Callable, Mapping, Sequence
from typing import Any, BinaryIO, Protocol, cast

import psutil

from .protocol import MAX_LINE_BYTES, ProbeMessage, ProtocolError, ProtocolValidator, decode_message

DEFAULT_QUEUE_SIZE = 64
DEFAULT_CLOSE_TIMEOUT = 2.0
DEFAULT_STDERR_LIMIT = 16 * 1024


class TransportError(RuntimeError):
    """Raised when a probe transport closes or its child process fails."""


class _Process(Protocol):
    stdin: BinaryIO
    stdout: BinaryIO
    stderr: BinaryIO
    pid: int
    returncode: int | None

    def poll(self) -> int | None: ...

    def wait(self, timeout: float | None = None) -> int: ...


_QueueItem = ProbeMessage | BaseException


def _encode_command(command: Mapping[str, Any], token: str, sequence: int) -> bytes:
    message_type = command.get("type")
    if not isinstance(message_type, str):
        raise TypeError("command must contain a string type")
    fields = {key: value for key, value in command.items() if key not in {"v", "seq", "token"}}
    payload = {"v": 1, "seq": sequence, "token": token, **fields}
    text = json.dumps(payload, separators=(",", ":"), ensure_ascii=False) + "\n"
    encoded = text.encode("utf-8")
    if len(encoded) > MAX_LINE_BYTES:
        raise ProtocolError("line exceeds 64 KiB limit")
    return encoded


def _read_protocol_line(stream: BinaryIO) -> bytes:
    line = stream.readline(MAX_LINE_BYTES + 1)
    if len(line) > MAX_LINE_BYTES:
        raise ProtocolError("line exceeds 64 KiB limit")
    if line and not line.endswith(b"\n"):
        raise ProtocolError("truncated protocol line")
    return line


class _MessageReader:
    def __init__(
        self,
        stream: BinaryIO,
        token: str,
        *,
        queue_size: int,
        eof_error: Callable[[], BaseException],
    ) -> None:
        if queue_size < 1:
            raise ValueError("queue_size must be positive")
        self._stream = stream
        self._validator = ProtocolValidator(token)
        self._queue: queue.Queue[_QueueItem] = queue.Queue(maxsize=queue_size)
        self._eof_error = eof_error
        self._closing = threading.Event()
        self._thread = threading.Thread(target=self._run, name="probe-protocol-reader", daemon=True)

    @property
    def pending_count(self) -> int:
        return self._queue.qsize()

    def start(self) -> None:
        self._thread.start()

    def _put(self, item: _QueueItem) -> None:
        while not self._closing.is_set():
            try:
                self._queue.put(item, timeout=0.05)
                return
            except queue.Full:
                continue

    def _run(self) -> None:
        try:
            while not self._closing.is_set():
                line = _read_protocol_line(self._stream)
                if not line:
                    self._put(self._eof_error())
                    return
                message = decode_message(line)
                self._validator.validate(message)
                self._put(message)
        except (OSError, ValueError) as exc:
            if not self._closing.is_set():
                self._put(TransportError(f"protocol read failed: {exc}"))
        except ProtocolError as exc:
            self._put(exc)

    def receive(self, timeout: float, timeout_name: str) -> ProbeMessage:
        if timeout <= 0:
            raise ValueError("timeout must be positive")
        try:
            item = self._queue.get(timeout=timeout)
        except queue.Empty as exc:
            raise TimeoutError(f"{timeout_name} timed out after {timeout:.3g} seconds") from exc
        if isinstance(item, BaseException):
            raise item
        return item

    def close(self) -> None:
        self._closing.set()


class PluginListener:
    """Accept exactly one authenticated plugin connection on numeric loopback."""

    def __init__(
        self,
        token: str | None = None,
        *,
        queue_size: int = DEFAULT_QUEUE_SIZE,
        accept_timeout: float = 30.0,
    ) -> None:
        self.token = token or secrets.token_urlsafe(32)
        self._queue_size = queue_size
        self._accept_timeout = accept_timeout
        self._listener: socket.socket | None = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._listener.bind(("127.0.0.1", 0))
        self._listener.listen(1)
        address, port = self._listener.getsockname()
        self.endpoint = f"{address}:{port}"
        self._connection: socket.socket | None = None
        self._stream: BinaryIO | None = None
        self._reader: _MessageReader | None = None
        self._accept_thread: threading.Thread | None = None
        self._accept_error: BaseException | None = None
        self._accepted = threading.Event()
        self._send_lock = threading.Lock()
        self._send_seq = 0
        self._closed = False

    @classmethod
    def from_socket(
        cls,
        connection: socket.socket,
        token: str,
        *,
        queue_size: int = DEFAULT_QUEUE_SIZE,
    ) -> PluginListener:
        self = cls.__new__(cls)
        self.token = token
        self._queue_size = queue_size
        self._accept_timeout = 0.0
        self._listener = None
        self.endpoint = ""
        self._connection = connection
        self._stream = connection.makefile("rb")
        self._reader = None
        self._accept_thread = None
        self._accept_error = None
        self._accepted = threading.Event()
        self._accepted.set()
        self._send_lock = threading.Lock()
        self._send_seq = 0
        self._closed = False
        return self

    @property
    def pending_count(self) -> int:
        return 0 if self._reader is None else self._reader.pending_count

    def start(self) -> None:
        if self._closed:
            raise TransportError("plugin listener is closed")
        if self._accept_thread is not None or self._reader is not None:
            return
        if self._connection is not None:
            self._start_reader()
            return
        self._accept_thread = threading.Thread(
            target=self._accept_one, name="probe-plugin-accept", daemon=True
        )
        self._accept_thread.start()

    def _accept_one(self) -> None:
        assert self._listener is not None
        try:
            self._listener.settimeout(self._accept_timeout)
            connection, _ = self._listener.accept()
            self._connection = connection
            self._stream = connection.makefile("rb")
            self._start_reader()
        except TimeoutError:
            self._accept_error = TimeoutError(
                f"plugin connection timed out after {self._accept_timeout:.3g} seconds"
            )
        except OSError as exc:
            if not self._closed:
                self._accept_error = TransportError(f"plugin accept failed: {exc}")
        finally:
            self._accepted.set()
            self._listener.close()

    def _start_reader(self) -> None:
        assert self._stream is not None
        self._reader = _MessageReader(
            self._stream,
            self.token,
            queue_size=self._queue_size,
            eof_error=lambda: TransportError("plugin connection closed"),
        )
        self._reader.start()

    def receive(self, *, timeout: float, timeout_name: str) -> ProbeMessage:
        if self._accept_thread is None and self._reader is None:
            self.start()
        deadline = time.monotonic() + timeout
        if not self._accepted.wait(timeout):
            raise TimeoutError(f"{timeout_name} timed out after {timeout:.3g} seconds")
        if self._accept_error is not None:
            raise self._accept_error
        reader = self._reader
        if reader is None:
            raise TransportError("plugin reader did not start")
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError(f"{timeout_name} timed out after {timeout:.3g} seconds")
        return reader.receive(remaining, timeout_name)

    def send(
        self,
        command: Mapping[str, Any],
        *,
        timeout: float = 2.0,
        timeout_name: str = "plugin command",
    ) -> None:
        if timeout <= 0:
            raise ValueError("timeout must be positive")
        if self._accept_thread is None and self._reader is None:
            self.start()
        deadline = time.monotonic() + timeout
        if not self._accepted.wait(timeout):
            raise TimeoutError(f"{timeout_name} timed out after {timeout:.3g} seconds")
        if self._accept_error is not None:
            raise self._accept_error
        connection = self._connection
        if connection is None:
            raise TransportError("plugin connection is unavailable")
        with self._send_lock:
            encoded = _encode_command(command, self.token, self._send_seq)
            view = memoryview(encoded)
            while view:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError(f"{timeout_name} timed out after {timeout:.3g} seconds")
                _, writable, _ = select.select([], [connection], [], remaining)
                if not writable:
                    raise TimeoutError(f"{timeout_name} timed out after {timeout:.3g} seconds")
                try:
                    sent = connection.send(view, socket.MSG_DONTWAIT)
                except BlockingIOError:
                    continue
                except TimeoutError:
                    raise
                except OSError as exc:
                    raise TransportError(f"plugin command write failed: {exc}") from exc
                if sent == 0:
                    raise TransportError("plugin connection closed during command write")
                view = view[sent:]
            self._send_seq += 1

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        if self._reader is not None:
            self._reader.close()
        if self._connection is not None:
            try:
                self._connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            self._connection.close()
        if self._stream is not None:
            self._stream.close()
        if self._listener is not None:
            self._listener.close()
        if self._accept_thread is not None:
            self._accept_thread.join(timeout=0.5)

    def __enter__(self) -> PluginListener:
        self.start()
        return self

    def __exit__(self, *_: object) -> None:
        self.close()


class HostProcess:
    """Own a native host process and its authenticated stdout protocol."""

    def __init__(
        self,
        command: Sequence[str],
        token: str | None = None,
        *,
        env: Mapping[str, str] | None = None,
        queue_size: int = DEFAULT_QUEUE_SIZE,
        stderr_limit: int = DEFAULT_STDERR_LIMIT,
        close_timeout: float = DEFAULT_CLOSE_TIMEOUT,
    ) -> None:
        self.token = token or secrets.token_urlsafe(32)
        child_env = os.environ.copy()
        if env is not None:
            child_env.update(env)
        child_env["YABRIDGE_PROBE_TOKEN"] = self.token
        process = subprocess.Popen(
            list(command),
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=child_env,
            start_new_session=True,
        )
        assert process.stdin is not None
        assert process.stdout is not None
        assert process.stderr is not None
        self._initialize(cast(_Process, process), queue_size, stderr_limit, close_timeout)

    @classmethod
    def from_process(
        cls,
        process: _Process,
        token: str,
        *,
        queue_size: int = DEFAULT_QUEUE_SIZE,
        stderr_limit: int = DEFAULT_STDERR_LIMIT,
        close_timeout: float = DEFAULT_CLOSE_TIMEOUT,
    ) -> HostProcess:
        self = cls.__new__(cls)
        self.token = token
        self._initialize(process, queue_size, stderr_limit, close_timeout)
        return self

    def _initialize(
        self,
        process: _Process,
        queue_size: int,
        stderr_limit: int,
        close_timeout: float,
    ) -> None:
        if stderr_limit < 1:
            raise ValueError("stderr_limit must be positive")
        self._process = process
        self._pgid = process.pid
        self._owns_process_group = not hasattr(process, "terminate_group")
        self._stderr_limit = stderr_limit
        self._stderr_chunks: deque[bytes] = deque()
        self._stderr_bytes = 0
        self._stderr_lock = threading.Lock()
        self._send_lock = threading.Lock()
        self._send_seq = 0
        self._close_timeout = close_timeout
        self._closed = False
        self._tracked_descendants: dict[int, float] = {}
        self._descendant_lock = threading.Lock()
        self._tracker_stop = threading.Event()
        self._tracker_thread: threading.Thread | None = None
        self._leader_identity: tuple[int, float] | None = None
        if self._owns_process_group:
            try:
                self._leader_identity = (process.pid, psutil.Process(process.pid).create_time())
            except (psutil.NoSuchProcess, psutil.AccessDenied):
                pass
            else:
                self._tracker_thread = threading.Thread(
                    target=self._track_descendants,
                    name="probe-host-descendants",
                    daemon=True,
                )
                self._tracker_thread.start()
        self._stderr_thread = threading.Thread(
            target=self._read_stderr, name="probe-host-stderr", daemon=True
        )
        self._reader = _MessageReader(
            process.stdout,
            self.token,
            queue_size=queue_size,
            eof_error=self._process_eof_error,
        )
        self._stderr_thread.start()
        self._reader.start()

    def _track_descendants(self) -> None:
        assert self._leader_identity is not None
        pid, create_time = self._leader_identity
        while not self._tracker_stop.is_set():
            try:
                leader = psutil.Process(pid)
                if leader.create_time() != create_time:
                    return
                descendants = leader.children(recursive=True)
            except (psutil.NoSuchProcess, psutil.ZombieProcess, psutil.AccessDenied):
                descendants = []
            identities: dict[int, float] = {}
            for descendant in descendants:
                try:
                    identities[descendant.pid] = descendant.create_time()
                except (psutil.NoSuchProcess, psutil.ZombieProcess, psutil.AccessDenied):
                    continue
            if identities:
                with self._descendant_lock:
                    self._tracked_descendants.update(identities)
            self._tracker_stop.wait(0.005)

    @property
    def pid(self) -> int:
        return self._process.pid

    @property
    def pending_count(self) -> int:
        return self._reader.pending_count

    @property
    def stderr_tail(self) -> str:
        with self._stderr_lock:
            return b"".join(self._stderr_chunks).decode("utf-8", errors="replace")

    def _read_stderr(self) -> None:
        while True:
            try:
                chunk = self._process.stderr.read(4096)
            except (OSError, ValueError):
                return
            if not chunk:
                return
            with self._stderr_lock:
                self._stderr_chunks.append(chunk)
                self._stderr_bytes += len(chunk)
                while self._stderr_bytes > self._stderr_limit and self._stderr_chunks:
                    excess = self._stderr_bytes - self._stderr_limit
                    first = self._stderr_chunks[0]
                    if len(first) <= excess:
                        self._stderr_chunks.popleft()
                        self._stderr_bytes -= len(first)
                    else:
                        self._stderr_chunks[0] = first[excess:]
                        self._stderr_bytes -= excess

    def _process_eof_error(self) -> BaseException:
        self._stderr_thread.join(timeout=0.2)
        status = self._process.poll()
        tail = self.stderr_tail.strip()
        if status is None:
            detail = "host stdout closed while process is running"
        else:
            detail = f"host exited with status {status}"
        if tail:
            detail += f"; stderr tail: {tail}"
        return TransportError(detail)

    def send(
        self,
        command: Mapping[str, Any],
        *,
        timeout: float = 2.0,
        timeout_name: str = "host command",
    ) -> None:
        if timeout <= 0:
            raise ValueError("timeout must be positive")
        with self._send_lock:
            encoded = _encode_command(command, self.token, self._send_seq)
            deadline = time.monotonic() + timeout
            try:
                descriptor = self._process.stdin.fileno()
            except (AttributeError, OSError):
                try:
                    self._process.stdin.write(encoded)
                    self._process.stdin.flush()
                except (BrokenPipeError, OSError, ValueError) as exc:
                    raise TransportError(f"host command write failed: {exc}") from exc
            else:
                was_blocking = os.get_blocking(descriptor)
                os.set_blocking(descriptor, False)
                view = memoryview(encoded)
                try:
                    while view:
                        remaining = deadline - time.monotonic()
                        if remaining <= 0:
                            self._raise_send_timeout(timeout_name, timeout)
                        try:
                            _, writable, _ = select.select([], [descriptor], [], remaining)
                        except InterruptedError:
                            continue
                        if not writable:
                            self._raise_send_timeout(timeout_name, timeout)
                        try:
                            written = os.write(descriptor, view)
                        except BlockingIOError:
                            continue
                        if written == 0:
                            raise TransportError("host stdin closed during command write")
                        view = view[written:]
                except TimeoutError:
                    raise
                except OSError as exc:
                    tail = self.stderr_tail.strip()
                    detail = f"host command write failed: {exc}"
                    if tail:
                        detail += f"; stderr tail: {tail}"
                    raise TransportError(detail) from exc
                finally:
                    os.set_blocking(descriptor, was_blocking)
            self._send_seq += 1

    def _raise_send_timeout(self, timeout_name: str, timeout: float) -> None:
        detail = f"{timeout_name} timed out after {timeout:.3g} seconds"
        tail = self.stderr_tail.strip()
        if tail:
            detail += f"; stderr tail: {tail}"
        raise TimeoutError(detail)

    def receive(self, *, timeout: float, timeout_name: str) -> ProbeMessage:
        try:
            return self._reader.receive(timeout, timeout_name)
        except TimeoutError as exc:
            tail = self.stderr_tail.strip()
            if tail:
                raise TimeoutError(f"{exc}; stderr tail: {tail}") from exc
            raise

    def _signal_group(self, sig: signal.Signals) -> None:
        process = self._process
        method_name = "terminate_group" if sig == signal.SIGTERM else "kill_group"
        method = getattr(process, method_name, None)
        if method is not None:
            cast(Any, method)()
            return
        try:
            os.killpg(self._pgid, sig)
        except ProcessLookupError:
            pass

    def _stop_descendant_tracker(self) -> None:
        self._tracker_stop.set()
        if self._tracker_thread is not None:
            self._tracker_thread.join(timeout=self._close_timeout)

    def _capture_session_members(self) -> None:
        if self._leader_identity is None:
            return
        leader_pid, leader_create_time = self._leader_identity
        try:
            current_leader = psutil.Process(leader_pid)
            if current_leader.create_time() != leader_create_time:
                return
        except psutil.NoSuchProcess:
            pass
        except (psutil.ZombieProcess, psutil.AccessDenied):
            return
        identities: dict[int, float] = {}
        for process in psutil.process_iter(["pid", "create_time"]):
            if process.pid == leader_pid:
                continue
            try:
                if os.getsid(process.pid) == self._pgid:
                    identities[process.pid] = process.create_time()
            except (ProcessLookupError, PermissionError, psutil.NoSuchProcess):
                continue
        with self._descendant_lock:
            self._tracked_descendants.update(identities)

    def _confirmed_descendants(self) -> list[psutil.Process]:
        with self._descendant_lock:
            identities = dict(self._tracked_descendants)
        confirmed = []
        for pid, create_time in identities.items():
            try:
                process = psutil.Process(pid)
                if (
                    process.create_time() == create_time
                    and process.status() != psutil.STATUS_ZOMBIE
                ):
                    confirmed.append(process)
            except (psutil.NoSuchProcess, psutil.ZombieProcess, psutil.AccessDenied):
                continue
        return confirmed

    def _terminate_confirmed_descendants(self) -> None:
        descendants = self._confirmed_descendants()
        for descendant in descendants:
            try:
                descendant.terminate()
            except (psutil.NoSuchProcess, psutil.AccessDenied):
                pass
        _, alive = psutil.wait_procs(descendants, timeout=self._close_timeout)
        confirmed_alive = {
            process.pid: process for process in self._confirmed_descendants()
        }
        for descendant in alive:
            current = confirmed_alive.get(descendant.pid)
            if current is not None:
                try:
                    current.kill()
                except (psutil.NoSuchProcess, psutil.AccessDenied):
                    pass
        psutil.wait_procs(list(confirmed_alive.values()), timeout=self._close_timeout)

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        self._reader.close()
        try:
            self._process.stdin.close()
        except (OSError, ValueError):
            pass
        leader_running = self._process.poll() is None
        close_error: TransportError | None = None
        if leader_running:
            self._signal_group(signal.SIGTERM)
            try:
                self._process.wait(timeout=self._close_timeout)
            except subprocess.TimeoutExpired:
                self._signal_group(signal.SIGKILL)
                try:
                    self._process.wait(timeout=self._close_timeout)
                except subprocess.TimeoutExpired:
                    close_error = TransportError(
                        "host process group did not exit after SIGKILL"
                    )
        self._capture_session_members()
        self._stop_descendant_tracker()
        if self._owns_process_group:
            self._terminate_confirmed_descendants()
        for stream in (self._process.stdout, self._process.stderr):
            try:
                stream.close()
            except (OSError, ValueError):
                pass
        self._stderr_thread.join(timeout=self._close_timeout)
        if close_error is not None:
            raise close_error

    def __enter__(self) -> HostProcess:
        return self

    def __exit__(self, *_: object) -> None:
        self.close()
