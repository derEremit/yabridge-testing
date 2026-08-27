"""Unit tests for the coordinate probe JSONL protocol."""

import json

import pytest

from yabridge_test.probe.protocol import (
    MAX_LINE_BYTES,
    ProtocolError,
    ProtocolValidator,
    decode_message,
)


def _line(payload: dict[str, object]) -> bytes:
    return (json.dumps(payload, separators=(",", ":")) + "\n").encode()


def test_decode_valid_v1_event() -> None:
    message = decode_message(_line({"v": 1, "seq": 0, "type": "hello", "plugin_id": "coordprobe"}))
    assert message.version == 1
    assert message.seq == 0
    assert message.type == "hello"
    assert message.fields["plugin_id"] == "coordprobe"


def test_decode_valid_v1_command() -> None:
    message = decode_message(_line({"v": 1, "seq": 1, "type": "warp", "x": 517, "y": 361}))
    assert message.type == "warp"
    assert message.fields["x"] == 517
    assert message.fields["y"] == 361


def test_decode_accepts_unknown_fields_for_forward_compatibility() -> None:
    message = decode_message(
        _line({"v": 1, "seq": 2, "type": "origin", "x": 317, "y": 211, "future": True})
    )
    assert message.fields["future"] is True


def test_decode_rejects_malformed_json() -> None:
    with pytest.raises(ProtocolError, match="malformed JSON"):
        decode_message(b'{"v":1,"seq":0,"type":"hello"\n')


def test_decode_rejects_truncated_json() -> None:
    with pytest.raises(ProtocolError, match="truncated JSON"):
        decode_message(b'{"v":1,"seq":0,"type":"hel')


def test_decode_rejects_truncated_incomplete_value() -> None:
    with pytest.raises(ProtocolError, match="truncated JSON"):
        decode_message(b'{"v":1,"seq":')


def test_decode_rejects_malformed_trailing_comma() -> None:
    with pytest.raises(ProtocolError, match="malformed JSON"):
        decode_message(b'{"v":1,"seq":0,"type":"hello",}\n')


def test_decode_rejects_malformed_unquoted_key() -> None:
    with pytest.raises(ProtocolError, match="malformed JSON"):
        decode_message(b"{v:1}\n")


def test_decode_rejects_malformed_extra_trailing_data() -> None:
    with pytest.raises(ProtocolError, match="malformed JSON"):
        decode_message(b'{"v":1} extra\n')


def test_decode_rejects_non_object_json() -> None:
    with pytest.raises(ProtocolError, match="expected JSON object"):
        decode_message(b"[1,2,3]\n")


def test_decode_rejects_invalid_utf8() -> None:
    with pytest.raises(ProtocolError, match="invalid UTF-8"):
        decode_message(b"\xff\xfe\n")


def test_decode_rejects_oversized_line() -> None:
    oversized = b"x" * (MAX_LINE_BYTES + 1)
    with pytest.raises(ProtocolError, match="line exceeds 64 KiB limit"):
        decode_message(oversized)


def test_decode_rejects_unsupported_protocol_version() -> None:
    with pytest.raises(ProtocolError, match="unsupported protocol version"):
        decode_message(_line({"v": 2, "seq": 0, "type": "hello", "plugin_id": "coordprobe"}))


def test_decode_rejects_negative_sequence() -> None:
    with pytest.raises(ProtocolError, match="sequence must be a nonnegative integer"):
        decode_message(_line({"v": 1, "seq": -1, "type": "hello", "plugin_id": "coordprobe"}))


def test_decode_rejects_unrecognized_message_type() -> None:
    with pytest.raises(ProtocolError, match="unrecognized message type"):
        decode_message(_line({"v": 1, "seq": 0, "type": "unknown", "plugin_id": "coordprobe"}))


def test_decode_rejects_missing_required_fields() -> None:
    with pytest.raises(ProtocolError, match="missing required field 'plugin_id'"):
        decode_message(_line({"v": 1, "seq": 0, "type": "hello"}))


def test_validator_rejects_wrong_token() -> None:
    validator = ProtocolValidator(expected_token="secret")
    message = decode_message(
        _line({"v": 1, "seq": 0, "type": "hello", "plugin_id": "coordprobe", "token": "wrong"})
    )
    with pytest.raises(ProtocolError, match="invalid authentication token"):
        validator.validate(message)


def test_validator_accepts_matching_token() -> None:
    validator = ProtocolValidator(expected_token="secret")
    message = decode_message(
        _line({"v": 1, "seq": 0, "type": "hello", "plugin_id": "coordprobe", "token": "secret"})
    )
    validator.validate(message)


def test_validator_rejects_duplicate_sequence() -> None:
    validator = ProtocolValidator(expected_token="secret")
    first = decode_message(
        _line({"v": 1, "seq": 0, "type": "hello", "plugin_id": "coordprobe", "token": "secret"})
    )
    duplicate = decode_message(
        _line({"v": 1, "seq": 0, "type": "origin", "x": 1, "y": 2, "token": "secret"})
    )
    validator.validate(first)
    with pytest.raises(ProtocolError, match="duplicate sequence number"):
        validator.validate(duplicate)


def test_validator_rejects_out_of_order_sequence() -> None:
    validator = ProtocolValidator(expected_token="secret")
    first = decode_message(
        _line({"v": 1, "seq": 0, "type": "hello", "plugin_id": "coordprobe", "token": "secret"})
    )
    out_of_order = decode_message(
        _line({"v": 1, "seq": 2, "type": "origin", "x": 1, "y": 2, "token": "secret"})
    )
    validator.validate(first)
    with pytest.raises(ProtocolError, match="out-of-order sequence number"):
        validator.validate(out_of_order)
