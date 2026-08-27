import json
from pathlib import Path

import pytest

from yabridge_test.provenance import ProvenanceError, StagingIdentity

VALID_COMMIT = "48ea9749b682c48875366134a42073d6b3d0a8c4"
OTHER_COMMIT = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
VALID_REF = "master"


def write_component_state(
    root: Path,
    *,
    ref: str = VALID_REF,
    commit: str = VALID_COMMIT,
    extra_lines: list[str] | None = None,
) -> None:
    state_dir = root / "build"
    state_dir.mkdir(parents=True)
    lines = [
        f"YABRIDGE_REF={ref}",
        f"YABRIDGE_COMMIT={commit}",
    ]
    if extra_lines:
        lines.extend(extra_lines)
    (state_dir / "component-state.env").write_text("\n".join(lines) + "\n")


def write_manifest(
    root: Path,
    *,
    ref: str = VALID_REF,
    commit: str = VALID_COMMIT,
    schema_version: int = 1,
    extra: dict[str, object] | None = None,
) -> None:
    manifest_dir = root / "run-state"
    manifest_dir.mkdir(parents=True)
    manifest: dict[str, object] = {
        "schema_version": schema_version,
        "yabridge_requested_ref": ref,
        "yabridge_commit": commit,
    }
    if extra:
        manifest.update(extra)
    (manifest_dir / "run-manifest.json").write_text(json.dumps(manifest) + "\n")


def test_loads_exact_commit_and_ref_from_component_state(tmp_path: Path) -> None:
    write_component_state(tmp_path)

    identity = StagingIdentity.load(tmp_path)

    assert identity is not None
    assert identity.ref == VALID_REF
    assert identity.commit == VALID_COMMIT


def test_loads_from_manifest_without_component_state(tmp_path: Path) -> None:
    write_manifest(tmp_path)

    identity = StagingIdentity.load(tmp_path)

    assert identity is not None
    assert identity.ref == VALID_REF
    assert identity.commit == VALID_COMMIT


def test_uses_manifest_when_manifest_and_matching_component_state_exist(
    tmp_path: Path,
) -> None:
    write_component_state(tmp_path)
    write_manifest(tmp_path)

    identity = StagingIdentity.load(tmp_path)

    assert identity is not None
    assert identity.ref == VALID_REF
    assert identity.commit == VALID_COMMIT


def test_falls_back_to_component_state_when_no_manifest(tmp_path: Path) -> None:
    write_component_state(tmp_path)

    identity = StagingIdentity.load(tmp_path)

    assert identity is not None
    assert identity.ref == VALID_REF
    assert identity.commit == VALID_COMMIT


def test_manifest_commit_mismatch_with_component_state_fails_closed(
    tmp_path: Path,
) -> None:
    write_component_state(tmp_path, commit=VALID_COMMIT)
    write_manifest(tmp_path, commit=OTHER_COMMIT)

    with pytest.raises(ProvenanceError):
        StagingIdentity.load(tmp_path)


def test_malformed_manifest_fails_closed(tmp_path: Path) -> None:
    write_component_state(tmp_path)
    manifest_dir = tmp_path / "run-state"
    manifest_dir.mkdir(parents=True)
    (manifest_dir / "run-manifest.json").write_text("{not json")

    with pytest.raises(ProvenanceError):
        StagingIdentity.load(tmp_path)


def test_unsupported_manifest_schema_version_fails_closed(tmp_path: Path) -> None:
    write_component_state(tmp_path)
    write_manifest(tmp_path, schema_version=99)

    with pytest.raises(ProvenanceError):
        StagingIdentity.load(tmp_path)


def test_invalid_manifest_commit_fails_closed(tmp_path: Path) -> None:
    write_component_state(tmp_path)
    write_manifest(tmp_path, commit="not-a-valid-commit")

    with pytest.raises(ProvenanceError):
        StagingIdentity.load(tmp_path)


def test_shell_injection_in_component_state_is_never_executed_or_parsed(
    tmp_path: Path,
) -> None:
    owned = tmp_path / "owned"
    state_dir = tmp_path / "build"
    state_dir.mkdir(parents=True)
    (state_dir / "component-state.env").write_text(
        f"YABRIDGE_REF={VALID_REF}\nYABRIDGE_COMMIT=$(touch {owned})\n"
    )

    with pytest.raises(ProvenanceError):
        StagingIdentity.load(tmp_path)

    assert not owned.exists()


def test_missing_provenance_returns_none(tmp_path: Path) -> None:
    assert StagingIdentity.load(tmp_path) is None


def test_loads_optional_bridge_roots_from_manifest(tmp_path: Path) -> None:
    write_manifest(
        tmp_path,
        extra={
            "bridge_roots": [
                "/tmp/home/.vst/yabridge",
                "/tmp/home/.vst3/yabridge",
            ],
        },
    )

    identity = StagingIdentity.load(tmp_path)

    assert identity is not None
    assert identity.bridge_roots == (
        Path("/tmp/home/.vst/yabridge"),
        Path("/tmp/home/.vst3/yabridge"),
    )
