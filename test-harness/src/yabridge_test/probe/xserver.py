"""Collision-safe X server lifecycle for coordinate probe runs."""

from __future__ import annotations

import atexit
import ctypes
import fcntl
import os
import shutil
import signal
import subprocess
import threading
import time
from collections.abc import Iterable, Mapping
from pathlib import Path
from types import FrameType, TracebackType
from typing import IO, Any


class XServerError(RuntimeError):
    """Raised when a requested X server mode cannot be established safely."""


class DisplayAllocator:
    """Reserve an unused X display number with an advisory process lock."""

    def __init__(
        self,
        *,
        lock_dir: Path = Path("/tmp/yabridge-test-x11"),
        socket_dir: Path = Path("/tmp/.X11-unix"),
        server_lock_dir: Path = Path("/tmp"),
        numbers: Iterable[int] = range(80, 220),
    ) -> None:
        self.lock_dir = lock_dir
        self.socket_dir = socket_dir
        self.server_lock_dir = server_lock_dir
        self.numbers = tuple(numbers)
        self.number: int | None = None
        self._stream: IO[str] | None = None

    def acquire(self) -> int:
        if self.number is not None:
            return self.number
        self.lock_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        for number in self.numbers:
            if (self.socket_dir / f"X{number}").exists():
                continue
            if (self.server_lock_dir / f".X{number}-lock").exists():
                continue
            path = self.lock_dir / f"display-{number}.lock"
            stream = path.open("a+", encoding="utf-8")
            try:
                fcntl.flock(stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                stream.close()
                continue
            if (self.socket_dir / f"X{number}").exists() or (
                self.server_lock_dir / f".X{number}-lock"
            ).exists():
                stream.close()
                continue
            stream.seek(0)
            stream.truncate()
            stream.write(f"{os.getpid()}\n")
            stream.flush()
            self._stream = stream
            self.number = number
            return number
        raise XServerError("no collision-free X11 display number is available")

    def release(self) -> None:
        if self._stream is not None:
            try:
                fcntl.flock(self._stream.fileno(), fcntl.LOCK_UN)
            finally:
                self._stream.close()
            self._stream = None
        self.number = None


def _terminate_group(process: subprocess.Popen[bytes], timeout: float = 2.0) -> None:
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=timeout)


class _Pointer:
    def __init__(self, display_name: str) -> None:
        try:
            self._x11 = ctypes.CDLL("libX11.so.6")
        except OSError as exc:
            raise XServerError("libX11.so.6 is required to preserve the pointer") from exc
        self._x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
        self._x11.XOpenDisplay.restype = ctypes.c_void_p
        self._x11.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
        self._x11.XDefaultRootWindow.restype = ctypes.c_ulong
        self._x11.XQueryPointer.argtypes = [
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
        self._x11.XWarpPointer.argtypes = [
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
        self._x11.XSync.argtypes = [ctypes.c_void_p, ctypes.c_int]
        self._x11.XCloseDisplay.argtypes = [ctypes.c_void_p]
        self._display = self._x11.XOpenDisplay(display_name.encode())
        if not self._display:
            raise XServerError(f"could not open existing X display {display_name}")
        self._root = self._x11.XDefaultRootWindow(self._display)

    def position(self) -> tuple[int, int]:
        root = ctypes.c_ulong()
        child = ctypes.c_ulong()
        root_x = ctypes.c_int()
        root_y = ctypes.c_int()
        window_x = ctypes.c_int()
        window_y = ctypes.c_int()
        state = ctypes.c_uint()
        if not self._x11.XQueryPointer(
            self._display,
            self._root,
            ctypes.byref(root),
            ctypes.byref(child),
            ctypes.byref(root_x),
            ctypes.byref(root_y),
            ctypes.byref(window_x),
            ctypes.byref(window_y),
            ctypes.byref(state),
        ):
            raise XServerError("XQueryPointer failed on the existing display")
        return root_x.value, root_y.value

    def warp(self, position: tuple[int, int]) -> None:
        if not self._x11.XWarpPointer(
            self._display,
            0,
            self._root,
            0,
            0,
            0,
            0,
            position[0],
            position[1],
        ):
            raise XServerError("could not restore the pointer on the existing display")
        self._x11.XSync(self._display, 0)

    def close(self) -> None:
        if self._display:
            self._x11.XCloseDisplay(self._display)
            self._display = None


class XServer:
    """Own Xvfb/Openbox or safely borrow an explicitly approved display."""

    def __init__(
        self,
        *,
        headless: bool,
        wm_managed: bool = False,
        allow_pointer_warp: bool = False,
        environ: Mapping[str, str] | None = None,
        ready_timeout: float = 5.0,
    ) -> None:
        self.headless = headless
        self.wm_managed = wm_managed
        self.allow_pointer_warp = allow_pointer_warp
        self.environ = dict(os.environ if environ is None else environ)
        self.ready_timeout = ready_timeout
        self.display = ""
        self._allocator: DisplayAllocator | None = None
        self._xvfb: subprocess.Popen[bytes] | None = None
        self._openbox: subprocess.Popen[bytes] | None = None
        self._pointer: _Pointer | None = None
        self._saved_pointer: tuple[int, int] | None = None
        self._closed = False
        self._prior_handlers: dict[signal.Signals, Any] = {}

    def require_pointer_warp(self) -> None:
        if not self.headless and not self.allow_pointer_warp:
            raise XServerError(
                "existing display pointer warping requires explicit opt-in "
                "(--no-headless with pointer-warp approval)"
            )

    def _install_handlers(self) -> None:
        if threading.current_thread() is not threading.main_thread():
            return
        for sig in (signal.SIGINT, signal.SIGTERM):
            previous = signal.getsignal(sig)
            self._prior_handlers[sig] = previous

            def handler(
                received: int,
                frame: FrameType | None,
                *,
                prior: Any = previous,
            ) -> None:
                self.close()
                if callable(prior):
                    prior(received, frame)
                elif prior == signal.SIG_DFL:
                    raise KeyboardInterrupt

            signal.signal(sig, handler)

    def _start_xvfb(self) -> None:
        xvfb = shutil.which("Xvfb")
        xdpyinfo = shutil.which("xdpyinfo")
        if xvfb is None or xdpyinfo is None:
            raise XServerError("Xvfb and xdpyinfo are required for headless probing")
        self._allocator = DisplayAllocator()
        self.display = f":{self._allocator.acquire()}"
        env = {
            **self.environ,
            "DISPLAY": self.display,
            "LIBGL_ALWAYS_SOFTWARE": "1",
            "__GLX_VENDOR_LIBRARY_NAME": "mesa",
        }
        self._xvfb = subprocess.Popen(
            [
                xvfb,
                self.display,
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
            env=env,
            start_new_session=True,
        )
        deadline = time.monotonic() + self.ready_timeout
        while True:
            if self._xvfb.poll() is not None:
                assert self._xvfb.stderr is not None
                error = self._xvfb.stderr.read().decode(errors="replace")
                raise XServerError(f"Xvfb exited before readiness: {error}")
            check = subprocess.run(
                [xdpyinfo, "-display", self.display],
                env=env,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
                timeout=1.0,
            )
            if check.returncode == 0:
                break
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise XServerError(
                    f"Xvfb readiness timed out after {self.ready_timeout:g} seconds"
                )
            threading.Event().wait(min(0.02, remaining))
        if self.wm_managed:
            self._start_openbox(env)

    def _start_openbox(self, env: Mapping[str, str]) -> None:
        openbox = shutil.which("openbox")
        xprop = shutil.which("xprop")
        if openbox is None or xprop is None:
            raise XServerError("Openbox and xprop are required for wm_managed")
        self._openbox = subprocess.Popen(
            [openbox, "--sm-disable"],
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
        deadline = time.monotonic() + self.ready_timeout
        while True:
            if self._openbox.poll() is not None:
                assert self._openbox.stderr is not None
                error = self._openbox.stderr.read().decode(errors="replace")
                raise XServerError(f"Openbox exited before readiness: {error}")
            check = subprocess.run(
                [xprop, "-root", "_NET_SUPPORTING_WM_CHECK"],
                env=env,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
                timeout=1.0,
            )
            if check.returncode == 0:
                return
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise XServerError(
                    f"Openbox readiness timed out after {self.ready_timeout:g} seconds"
                )
            threading.Event().wait(min(0.02, remaining))

    def start_window_manager(self) -> None:
        """Start Openbox on an already-ready owned Xvfb display."""
        if not self.headless or self._xvfb is None:
            raise XServerError("wm_managed requires an owned headless Xvfb display")
        if self._openbox is not None:
            return
        self._start_openbox({**self.environ, "DISPLAY": self.display})

    def __enter__(self) -> XServer:
        self._closed = False
        if self.headless:
            self._start_xvfb()
        else:
            self.display = self.environ.get("DISPLAY", "")
            if not self.display:
                raise XServerError("existing display mode requires DISPLAY")
            self.require_pointer_warp()
            self._pointer = _Pointer(self.display)
            self._saved_pointer = self._pointer.position()
        self._install_handlers()
        atexit.register(self.close)
        return self

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        if self._pointer is not None:
            try:
                if self._saved_pointer is not None:
                    self._pointer.warp(self._saved_pointer)
            finally:
                self._pointer.close()
                self._pointer = None
        if self._openbox is not None:
            _terminate_group(self._openbox)
            if self._openbox.stderr is not None:
                self._openbox.stderr.close()
            self._openbox = None
        if self._xvfb is not None:
            _terminate_group(self._xvfb)
            if self._xvfb.stderr is not None:
                self._xvfb.stderr.close()
            self._xvfb = None
        if self._allocator is not None:
            self._allocator.release()
            self._allocator = None
        if threading.current_thread() is threading.main_thread():
            for sig, previous in self._prior_handlers.items():
                signal.signal(sig, previous)
        self._prior_handlers.clear()
        try:
            atexit.unregister(self.close)
        except Exception:
            pass

    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc: BaseException | None,
        traceback: TracebackType | None,
    ) -> None:
        self.close()
