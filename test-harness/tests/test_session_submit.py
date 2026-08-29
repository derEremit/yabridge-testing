"""isolated-daw session submit uses manifest scalars, never paths."""

from __future__ import annotations

from pathlib import Path

import pytest
from click.testing import CliRunner

from tests.test_provenance import VALID_COMMIT, VALID_REF, write_manifest
from yabridge_test.cli import main
from yabridge_test.sanitize import payload_for_submit
from yabridge_test.schemas import DisplayServer, Environment
from yabridge_test.session_report import build_session_report

HOME = "/home/operator/projects/yabridge-staging"


def _environment() -> Environment:
    return Environment(
        distro="Arch Linux",
        kernel="6.8.0",
        desktop="KDE Plasma",
        display_server=DisplayServer.WAYLAND,
        wine_version="wine-9.0",
        wine_prefix=f"{HOME}/prefix-copy",
        yabridge_version="5.1.1",
    )


def test_session_report_copies_scalars_not_paths(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    write_manifest(
        tmp_path,
        extra={
            "wine_version_string": "wine-11.8 (Staging)",
            "wine_installed_version": "11.8",
            "wine_sha256": "b" * 64,
            "wine_digest_verified": True,
            "daw_executable": f"{HOME}/isolation/bin/bitwig-studio",
            "clone_path": f"{HOME}/prefix-copy",
            "source_path": f"{HOME}/.wine",
            "bridge_home": f"{HOME}/isolation/home",
        },
    )
    monkeypatch.setenv("YABRIDGE_TEST_ROOT", str(tmp_path))
    monkeypatch.setattr(
        "yabridge_test.session_report.collect_environment", _environment
    )

    report = build_session_report(notes="first-click notes")
    payload = payload_for_submit(report)

    assert report.session_type == "isolated-daw"
    assert report.host == "bitwig-studio"
    assert report.environment.wine_version == "wine-11.8 (Staging)"
    assert report.environment.wine_digest_verified is True
    assert report.tests == []
    assert payload["session_type"] == "isolated-daw"
    assert payload["host"] == "bitwig-studio"
    assert payload["notes"] == "first-click notes"
    dumped = str(payload)
    assert HOME not in dumped
    assert "clone_path" not in dumped
    assert "source_path" not in dumped
    assert "bridge_home" not in dumped
    assert "/home/" not in dumped


def test_submit_session_dry_run_prints_sanitized_json(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    write_manifest(
        tmp_path,
        extra={
            "wine_version_string": "wine-11.8 (Staging)",
            "wine_sha256": "c" * 64,
            "wine_digest_verified": True,
            "daw_executable": f"{HOME}/bin/bitwig-studio",
            "clone_path": f"{HOME}/prefix-copy",
        },
    )
    monkeypatch.setenv("YABRIDGE_TEST_ROOT", str(tmp_path))
    monkeypatch.setattr(
        "yabridge_test.session_report.collect_environment", _environment
    )

    result = CliRunner().invoke(
        main,
        ["submit", "--session", "--notes", "first click", "--dry-run"],
    )

    assert result.exit_code == 0, result.output
    assert HOME not in result.output
    assert "/home/" not in result.output
    assert "isolated-daw" in result.output
    assert "bitwig-studio" in result.output
    assert "first click" in result.output
    assert VALID_COMMIT in result.output or VALID_REF in result.output


def test_session_report_carries_repo_and_patch_digests_but_never_a_local_path(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    write_manifest(
        tmp_path,
        extra={
            "yabridge_repo": "https://example.com/someone/yabridge.git",
            "yabridge_patches": ["c" * 64, "d" * 64],
            "daw_executable": f"{HOME}/isolation/bin/bitwig-studio",
        },
    )
    monkeypatch.setenv("YABRIDGE_TEST_ROOT", str(tmp_path))
    monkeypatch.setattr(
        "yabridge_test.session_report.collect_environment", _environment
    )

    payload = payload_for_submit(build_session_report())

    assert payload["report_version"] == "1.2.0"
    assert payload["environment"]["yabridge_repo"] == "https://example.com/someone/yabridge.git"
    assert payload["environment"]["yabridge_patches"] == ["c" * 64, "d" * 64]


def test_a_local_repository_directory_is_reported_as_local(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    write_manifest(tmp_path, extra={"yabridge_repo": f"{HOME}/src/yabridge"})
    monkeypatch.setenv("YABRIDGE_TEST_ROOT", str(tmp_path))
    monkeypatch.setattr(
        "yabridge_test.session_report.collect_environment", _environment
    )

    payload = payload_for_submit(build_session_report())

    assert payload["environment"]["yabridge_repo"] == "local"
    assert HOME not in str(payload)
