"""Versioned JSONL protocol for the coordinate probe."""

from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any

MAX_LINE_BYTES = 65536

_MESSAGE_TYPES = frozenset(
    {
        "hello",
        "attached",
        "mouse",
        "mark",
        "origin",
        "size",
        "error",
        "bye",
        "ready",
        "gui_opened",
        "warped",
        "geometry",
        "x11",
        "clap",
        "open",
        "place",
        "warp",
        "button",
        "resize",
        "synthetic_configure",
        "close",
    }
)

_REQUIRED_FIELDS: dict[str, tuple[str, ...]] = {
    "hello": ("plugin_id",),
    "attached": ("hwnd",),
    "mouse": ("x", "y"),
    "mark": ("label",),
    "origin": ("x", "y"),
    "size": ("w", "h"),
    "error": ("message",),
    "bye": (),
    "ready": (),
    "gui_opened": ("hwnd",),
    "warped": ("x", "y"),
    "geometry": ("x", "y", "w", "h"),
    "x11": ("window", "x", "y", "w", "h"),
    "clap": ("event",),
    "open": (),
    "place": ("x", "y", "w", "h"),
    "warp": ("x", "y"),
    "button": ("x", "y", "button"),
    "resize": ("w", "h"),
    "synthetic_configure": ("x", "y", "w", "h"),
    "close": (),
}


class ProtocolError(Exception):
    """Raised when a probe protocol line or session state is invalid."""


@dataclass(frozen=True)
class ProbeMessage:
    """One decoded JSONL probe message."""

    version: int
    seq: int
    type: str
    fields: dict[str, Any]


def decode_message(line: bytes) -> ProbeMessage:
    """Decode one JSONL line into a probe message."""
    if len(line) > MAX_LINE_BYTES:
        raise ProtocolError("line exceeds 64 KiB limit")

    if line.endswith(b"\n"):
        payload_bytes = line[:-1]
    else:
        payload_bytes = line

    try:
        text = payload_bytes.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ProtocolError("invalid UTF-8") from exc

    try:
        raw = json.loads(text)
    except json.JSONDecodeError as exc:
        if "Unterminated" in exc.msg or (exc.pos == len(text) and exc.msg == "Expecting value"):
            message = "truncated JSON"
        else:
            message = "malformed JSON"
        raise ProtocolError(message) from exc

    if not isinstance(raw, dict):
        raise ProtocolError("expected JSON object")

    if raw.get("v") != 1:
        raise ProtocolError("unsupported protocol version")

    seq = raw.get("seq")
    if not isinstance(seq, int) or seq < 0 or isinstance(seq, bool):
        raise ProtocolError("sequence must be a nonnegative integer")

    message_type = raw.get("type")
    if not isinstance(message_type, str) or message_type not in _MESSAGE_TYPES:
        raise ProtocolError("unrecognized message type")

    for field in _REQUIRED_FIELDS[message_type]:
        if field not in raw:
            raise ProtocolError(f"missing required field '{field}'")

    fields = {key: value for key, value in raw.items() if key not in {"v", "seq", "type"}}
    return ProbeMessage(version=1, seq=seq, type=message_type, fields=fields)


class ProtocolValidator:
    """Stateful validator for probe authentication and sequencing."""

    def __init__(self, expected_token: str) -> None:
        self._expected_token = expected_token
        self._seen_sequences: set[int] = set()
        self._next_sequence = 0

    def validate(self, message: ProbeMessage) -> None:
        """Validate token and sequence ordering for one decoded message."""
        token = message.fields.get("token")
        if token != self._expected_token:
            raise ProtocolError("invalid authentication token")

        if message.seq in self._seen_sequences:
            raise ProtocolError("duplicate sequence number")

        if message.seq != self._next_sequence:
            raise ProtocolError("out-of-order sequence number")

        self._seen_sequences.add(message.seq)
        self._next_sequence = message.seq + 1
