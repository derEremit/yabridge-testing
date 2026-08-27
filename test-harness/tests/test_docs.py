"""Documentation link and command consistency checks."""

from __future__ import annotations

import configparser
import json
import re
import shlex
from pathlib import Path

import click
import pytest
import yaml
from conftest import PURE_MARKER_EXPRESSION

from tests.test_probe_artifact import CLAP_REVISION, CLAP_WRAP
from yabridge_test.cli import main
from yabridge_test.probe import protocol
from yabridge_test.probe.protocol import ProtocolError, ProtocolValidator, decode_message
from yabridge_test.probe.scenarios import SCENARIO_NAMES

REPO_ROOT = Path(__file__).resolve().parents[2]
DOCS = REPO_ROOT / "docs"
COORD_PROBE = DOCS / "coord-probe.md"
TEST_HARNESS_README = REPO_ROOT / "test-harness" / "README.md"
WORKFLOWS = REPO_ROOT / ".github" / "workflows"

DOC_FILES = (
    COORD_PROBE,
    DOCS / "test-protocol.md",
    DOCS / "architecture.md",
    TEST_HARNESS_README,
)

MARKDOWN_LINK = re.compile(r"\[[^\]]+\]\(([^)]+)\)")
CODE_BLOCK = re.compile(r"```(?:bash|text|sh)?\n(.*?)```", re.DOTALL)
SCENARIO_TABLE_ROW = re.compile(r"^\| `([^`]+)` \|")
PROTOCOL_TYPE_NAME = re.compile(r"`([a-z0-9_]+)`")


def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def _clap_wrap_revision() -> str:
    parser = configparser.ConfigParser(interpolation=None)
    parser.read(CLAP_WRAP)
    return parser["wrap-git"]["revision"]


def _section(text: str, heading: str, *, until_heading: str | None = None) -> str:
    start = text.index(heading)
    if until_heading is None:
        next_heading = text.find("\n## ", start + len(heading))
        return text[start:] if next_heading == -1 else text[start:next_heading]
    end = text.index(until_heading, start + len(heading))
    return text[start:end]


def _protocol_section(text: str) -> str:
    return _section(text, "## Protocol v1", until_heading="## yabridge discovery")


def _scenarios_section(text: str) -> str:
    return _section(text, "## Scenarios")


def _documented_scenarios(text: str) -> list[str]:
    """Parse every scenario table row in the designated section."""
    scenarios: list[str] = []
    for line in _scenarios_section(text).splitlines():
        match = SCENARIO_TABLE_ROW.match(line)
        if match is not None:
            scenarios.append(match.group(1))
    return scenarios


def _documented_protocol_types(text: str) -> frozenset[str]:
    """Parse the complete supported-type list from the designated protocol block."""
    section = _protocol_section(text)
    marker = "Supported `type` values:"
    start = section.index(marker) + len(marker)
    types: set[str] = set()
    for line in section[start:].splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        found = PROTOCOL_TYPE_NAME.findall(stripped)
        if not found:
            break
        types.update(found)
    return frozenset(types)


def _protocol_line(payload: dict[str, object]) -> bytes:
    return (json.dumps(payload, separators=(",", ":")) + "\n").encode()


def _validated_message(
    validator: ProtocolValidator,
    *,
    seq: int,
    type_: str,
    token: str,
    **fields: object,
) -> None:
    message = decode_message(
        _protocol_line({"v": 1, "seq": seq, "type": type_, "token": token, **fields})
    )
    validator.validate(message)


def _parse_workflow(name: str) -> dict[str, object]:
    text = _read(WORKFLOWS / name)
    text = re.sub(r"^on:", '"on":', text, count=1, flags=re.MULTILINE)
    loaded = yaml.safe_load(text)
    assert isinstance(loaded, dict)
    return loaded


def _workflow_run_steps(name: str) -> str:
    workflow = _parse_workflow(name)
    job = next(iter(workflow["jobs"].values()))
    return "\n".join(
        step.get("name", "") + "\n" + step.get("run", "")
        for step in job["steps"]
        if "run" in step
    )


def _extract_cli_invocations(text: str) -> list[str]:
    invocations: list[str] = []
    for block in CODE_BLOCK.findall(text):
        current = ""
        for raw_line in block.splitlines():
            line = raw_line.strip()
            if not line or line.startswith("#"):
                if current:
                    invocations.append(current.strip())
                    current = ""
                continue
            if line.endswith("\\"):
                current += line[:-1].strip() + " "
                continue
            if current:
                line = current + line
                current = ""
            if line.startswith("yabridge-test") and "[" not in line and "|" not in line:
                invocations.append(line)
    return invocations


def _option_lookup(command: click.Command) -> dict[str, click.Option]:
    lookup: dict[str, click.Option] = {}
    for param in command.params:
        if isinstance(param, click.Option):
            for opt in (*param.opts, *param.secondary_opts):
                lookup[opt] = param
    return lookup


def _validate_cli_invocation(line: str) -> None:
    tokens = shlex.split(line)
    assert tokens and tokens[0] == "yabridge-test"
    rest = tokens[1:]
    if not rest:
        pytest.fail(f"incomplete documented command: {line}")
    command = main.commands.get(rest[0])
    if command is None:
        pytest.fail(f"unknown subcommand {rest[0]!r} in documented command: {line}")
    options = _option_lookup(command)
    args = rest[1:]
    index = 0
    while index < len(args):
        token = args[index]
        if token in options:
            param = options[token]
            index += 1
            if param.is_flag:
                continue
            if param.nargs == 1 and index < len(args) and not args[index].startswith("-"):
                index += 1
            continue
        if token.startswith("-"):
            pytest.fail(f"unknown option {token!r} in documented command: {line}")
        index += 1


@pytest.mark.parametrize("path", DOC_FILES, ids=lambda p: p.name)
def test_documentation_files_exist(path: Path) -> None:
    assert path.is_file(), f"missing documentation file: {path}"


@pytest.mark.parametrize("path", DOC_FILES, ids=lambda p: p.name)
def test_internal_markdown_links_resolve(path: Path) -> None:
    text = _read(path)
    for target in MARKDOWN_LINK.findall(text):
        if target.startswith(("http://", "https://", "#")):
            continue
        resolved = (path.parent / target).resolve()
        assert resolved.is_file(), f"{path.name} links to missing file: {target}"


def test_clap_revision_in_docs_matches_wrap_and_artifact_constant() -> None:
    wrap_revision = _clap_wrap_revision()
    assert wrap_revision == CLAP_REVISION
    assert wrap_revision in _read(COORD_PROBE)


def test_documented_scenarios_exactly_match_registry() -> None:
    documented = _documented_scenarios(_read(COORD_PROBE))
    registry = list(SCENARIO_NAMES)
    assert documented == registry


def test_documented_protocol_types_exactly_match_protocol_module() -> None:
    documented = _documented_protocol_types(_read(COORD_PROBE))
    assert documented == protocol._MESSAGE_TYPES


def test_documented_sequence_section_describes_validator_errors() -> None:
    section = _protocol_section(_read(COORD_PROBE))
    assert "duplicate sequence number" in section
    assert "out-of-order sequence number" in section


def test_documented_sequence_behavior_matches_protocol_validator() -> None:
    token = "doc-test-token"
    validator = ProtocolValidator(token)
    _validated_message(
        validator,
        seq=0,
        type_="hello",
        token=token,
        plugin_id="org.yabridge.coordprobe",
    )
    _validated_message(validator, seq=1, type_="origin", token=token, x=0, y=0)

    gap_validator = ProtocolValidator(token)
    _validated_message(
        gap_validator,
        seq=0,
        type_="hello",
        token=token,
        plugin_id="org.yabridge.coordprobe",
    )
    gap_message = decode_message(
        _protocol_line(
            {"v": 1, "seq": 2, "type": "origin", "token": token, "x": 0, "y": 0}
        )
    )
    with pytest.raises(ProtocolError, match="out-of-order sequence number"):
        gap_validator.validate(gap_message)

    duplicate_validator = ProtocolValidator(token)
    first = decode_message(
        _protocol_line(
            {
                "v": 1,
                "seq": 0,
                "type": "hello",
                "token": token,
                "plugin_id": "org.yabridge.coordprobe",
            }
        )
    )
    duplicate = decode_message(
        _protocol_line({"v": 1, "seq": 0, "type": "origin", "token": token, "x": 0, "y": 0})
    )
    duplicate_validator.validate(first)
    with pytest.raises(ProtocolError, match="duplicate sequence number"):
        duplicate_validator.validate(duplicate)

    out_of_order_validator = ProtocolValidator(token)
    _validated_message(
        out_of_order_validator,
        seq=0,
        type_="hello",
        token=token,
        plugin_id="org.yabridge.coordprobe",
    )
    _validated_message(out_of_order_validator, seq=1, type_="origin", token=token, x=0, y=0)
    skipped = decode_message(
        _protocol_line(
            {"v": 1, "seq": 3, "type": "origin", "token": token, "x": 1, "y": 1}
        )
    )
    with pytest.raises(ProtocolError, match="out-of-order sequence number"):
        out_of_order_validator.validate(skipped)


def test_scenario_parser_rejects_injected_extra_name() -> None:
    documented = _documented_scenarios(_read(COORD_PROBE))
    with pytest.raises(AssertionError):
        assert documented + ["injected_scenario"] == list(SCENARIO_NAMES)


def test_protocol_type_parser_rejects_injected_extra_name() -> None:
    documented = _documented_protocol_types(_read(COORD_PROBE))
    with pytest.raises(AssertionError):
        assert documented | {"injected_type"} == protocol._MESSAGE_TYPES


CLI_FILES = (
    COORD_PROBE,
    DOCS / "test-protocol.md",
    TEST_HARNESS_README,
)


@pytest.mark.parametrize("path", CLI_FILES, ids=lambda p: p.name)
def test_documented_cli_invocations_use_real_click_options(path: Path) -> None:
    invocations = _extract_cli_invocations(_read(path))
    assert invocations, f"{path.name} contains no documented yabridge-test invocations"
    for line in invocations:
        _validate_cli_invocation(line)


def test_documented_ci_workflows_match_repository_yaml() -> None:
    harness_steps = _workflow_run_steps("test-harness.yml")
    probe_steps = _workflow_run_steps("probe.yml")
    doc_text = _read(COORD_PROBE) + _read(TEST_HARNESS_README)

    assert "test-harness.yml" in doc_text
    assert "probe.yml" in doc_text
    assert PURE_MARKER_EXPRESSION in harness_steps
    assert 'pip install -e ".[dev]"' in harness_steps
    assert "python -m mypy src/" in harness_steps
    assert "python -m ruff check src/ tests/" in harness_steps
    assert "gcc-mingw-w64-x86-64" in probe_steps
    assert "tests/test_probe_artifact.py" in probe_steps
    assert "-m native_probe tests/test_probe_host.py" in probe_steps


def test_documented_mingw_packages_use_debian_spelling() -> None:
    for path in DOC_FILES:
        text = _read(path)
        assert "gcc-mingw-w64-x86_64" not in text, f"{path.name} uses wrong MinGW spelling"
        if "gcc-mingw" in text:
            assert "gcc-mingw-w64-x86-64" in text
