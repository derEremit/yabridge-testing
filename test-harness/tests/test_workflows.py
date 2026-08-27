"""Regression tests for GitHub Actions workflow path triggers and commands."""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

from conftest import (
    LIVE_PROBE_MARKER_EXPRESSION,
    NATIVE_PROBE_MARKER_EXPRESSION,
    PURE_MARKER_EXPRESSION,
    WINE_PROBE_MARKER_EXPRESSION,
)

REPO_ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = REPO_ROOT / ".github" / "workflows"
TEST_HARNESS = REPO_ROOT / "test-harness"


def _load_workflow(name: str) -> str:
    return (WORKFLOWS / name).read_text()


def _parse_workflow(name: str) -> dict[str, object]:
    """Parse workflow YAML without PyYAML 1.1 turning ``on`` into a boolean."""
    import yaml

    text = _load_workflow(name)
    text = re.sub(r"^on:", '"on":', text, count=1, flags=re.MULTILINE)
    loaded = yaml.safe_load(text)
    assert isinstance(loaded, dict)
    return loaded


def _run_steps(name: str) -> list[str]:
    workflow = _parse_workflow(name)
    job = next(iter(workflow["jobs"].values()))
    return [
        step.get("name", "") + "\n" + step.get("run", "")
        for step in job["steps"]
        if "run" in step
    ]


def _collect_test_ids(
    marker_expression: str | None = None,
    test_path: str | None = None,
) -> set[str]:
    command = [sys.executable, "-m", "pytest", "--collect-only", "-q"]
    if marker_expression is not None:
        command.extend(["-m", marker_expression])
    if test_path is not None:
        command.append(test_path)
    result = subprocess.run(
        command,
        cwd=TEST_HARNESS,
        capture_output=True,
        text=True,
        check=True,
    )
    return {
        line.split("::", 1)[-1]
        for line in result.stdout.splitlines()
        if "::" in line and not line.startswith("=")
    }


def _native_probe_test_ids() -> set[str]:
    return {
        test_id
        for test_id in _collect_test_ids()
        if test_id.startswith(
            (
                "test_probe_build_is_pinned_x86_64_and_reproducible",
                "test_no_plugin_geometry_matches_independent_x11",
                "test_real_binary_rejects_invalid_protocol",
                "test_real_binary_accepts_exact_64k_line",
                "test_plugin_fixture_",
                "test_synthetic_absolute_targets_host_parent_without_moving_bridge_windows",
                "test_plugin_resize_reports_observed_adjusted_geometry",
                "test_plugin_async_resize_waits_for_accepted_geometry",
            )
        )
    }


def _workflow_marker_expressions(name: str) -> set[str]:
    expressions: set[str] = set()
    pattern = re.compile(r"(?:^|\s)-m\s+(?:\"([^\"]+)\"|'([^']+)'|(\S+))")
    for step in _run_steps(name):
        for match in pattern.finditer(step):
            expressions.add(next(group for group in match.groups() if group is not None))
    return expressions


def test_build_images_is_packer_only() -> None:
    workflow = _parse_workflow("build-images.yml")
    triggers = workflow["on"]
    assert isinstance(triggers, dict)
    assert set(triggers["push"]["paths"]) == {
        "packer/**",
        ".github/workflows/build-images.yml",
    }
    assert set(triggers["pull_request"]["paths"]) == {"packer/**"}
    job_names = set(workflow["jobs"])
    assert job_names == {"validate", "build-ubuntu", "build-arch"}
    assert "test-harness" not in job_names
    assert "web-api" not in job_names


def test_test_harness_workflow_runs_pure_marker_matrix() -> None:
    workflow = _parse_workflow("test-harness.yml")
    triggers = workflow["on"]
    assert isinstance(triggers, dict)
    assert ".github/workflows/test-harness.yml" in triggers["push"]["paths"]
    assert "test-harness/**" in triggers["push"]["paths"]

    job = workflow["jobs"]["test"]
    assert job["strategy"]["matrix"]["python-version"] == ["3.10", "3.12"]

    joined = "\n".join(_run_steps("test-harness.yml"))
    assert 'pip install -e ".[dev]"' in joined
    assert PURE_MARKER_EXPRESSION in joined
    assert "python -m mypy src/" in joined
    assert "python -m ruff check src/ tests/" in joined
    assert "meson" not in joined
    assert "wineboot" not in joined
    assert "wineserver" not in joined
    assert "xvfb-run" not in joined
    assert NATIVE_PROBE_MARKER_EXPRESSION not in joined.replace(PURE_MARKER_EXPRESSION, "")


def test_probe_workflow_builds_before_native_marker_tests() -> None:
    workflow = _parse_workflow("probe.yml")
    triggers = workflow["on"]
    assert isinstance(triggers, dict)
    assert ".github/workflows/probe.yml" in triggers["push"]["paths"]
    assert "probe/**" in triggers["push"]["paths"]
    assert "test-harness/**" not in triggers["push"]["paths"]

    steps = _run_steps("probe.yml")
    joined = "\n".join(steps)
    build_index = next(index for index, step in enumerate(steps) if "meson setup" in step)
    artifact_index = next(
        index for index, step in enumerate(steps) if "test_probe_artifact.py" in step
    )
    native_host_index = next(
        index
        for index, step in enumerate(steps)
        if "test_probe_host.py" in step and "-m native_probe" in step
    )
    transport_index = next(
        index for index, step in enumerate(steps) if "test_probe_transport.py" in step
    )

    artifact_step = steps[artifact_index]
    assert "tests/test_probe_artifact.py" in artifact_step
    assert "-m native_probe" not in artifact_step
    assert build_index < artifact_index < native_host_index
    assert transport_index >= native_host_index
    assert "test_probe_transport.py" in steps[transport_index]
    assert "meson compile" in joined
    assert "mingw-w64-x86_64.ini" in joined
    assert "sha256sum" in joined
    assert WINE_PROBE_MARKER_EXPRESSION not in joined
    assert LIVE_PROBE_MARKER_EXPRESSION not in joined
    assert "YABRIDGE_LIVE_LIB" not in joined


def test_probe_workflow_owns_unmarked_revision_test_on_probe_only_paths() -> None:
    artifact_ids = _collect_test_ids(test_path="tests/test_probe_artifact.py")
    assert artifact_ids == {
        "test_clap_wrap_has_exact_immutable_revision",
        "test_probe_build_is_pinned_x86_64_and_reproducible",
    }

    artifact_step = next(
        step for step in _run_steps("probe.yml") if "test_probe_artifact.py" in step
    )
    assert "python -m pytest -q tests/test_probe_artifact.py" in artifact_step
    assert "test_clap_wrap_has_exact_immutable_revision" in artifact_ids
    assert "test_clap_wrap_has_exact_immutable_revision" not in _collect_test_ids(
        NATIVE_PROBE_MARKER_EXPRESSION, test_path="tests/test_probe_artifact.py"
    )


def test_marker_categories_have_expected_workflow_ownership() -> None:
    native_ids = _collect_test_ids(NATIVE_PROBE_MARKER_EXPRESSION)
    wine_ids = _collect_test_ids(WINE_PROBE_MARKER_EXPRESSION)
    live_ids = _collect_test_ids(LIVE_PROBE_MARKER_EXPRESSION)
    pure_ids = _collect_test_ids(PURE_MARKER_EXPRESSION)

    assert native_ids == _native_probe_test_ids()
    assert wine_ids == {"test_pure_wine_host_reports_client_mouse_coordinates"}
    assert live_ids == {"test_live_offset_probe_opt_in"}

    assert "test_clap_wrap_has_exact_immutable_revision" in pure_ids
    assert "test_baseline_commands_are_strict_valid_protocol" in pure_ids
    assert "test_plugin_listener_timeout_is_named" in pure_ids
    assert any(
        name.startswith("test_all_scenarios_execute_distinct_golden_semantics")
        for name in pure_ids
    )
    assert native_ids.isdisjoint(pure_ids)
    assert wine_ids.isdisjoint(pure_ids)
    assert live_ids.isdisjoint(pure_ids)
    assert len(pure_ids) >= 150


def test_marker_partitions_match_ci_ownership() -> None:
    pure_ids = _collect_test_ids(PURE_MARKER_EXPRESSION)
    runtime_categories = {
        NATIVE_PROBE_MARKER_EXPRESSION: _collect_test_ids(
            NATIVE_PROBE_MARKER_EXPRESSION
        ),
        WINE_PROBE_MARKER_EXPRESSION: _collect_test_ids(WINE_PROBE_MARKER_EXPRESSION),
        LIVE_PROBE_MARKER_EXPRESSION: _collect_test_ids(LIVE_PROBE_MARKER_EXPRESSION),
    }

    artifact_or_runtime_ids = set().union(*runtime_categories.values())
    assert pure_ids.isdisjoint(artifact_or_runtime_ids)
    for expression, node_ids in runtime_categories.items():
        other_ids = set().union(
            *(
                category_ids
                for category, category_ids in runtime_categories.items()
                if category != expression
            )
        )
        assert node_ids.isdisjoint(other_ids)

    workflow_markers = {
        name: _workflow_marker_expressions(name)
        for name in ("test-harness.yml", "probe.yml")
    }
    owners = {
        expression: {
            workflow
            for workflow, expressions in workflow_markers.items()
            if expression in expressions
        }
        for expression in (
            PURE_MARKER_EXPRESSION,
            NATIVE_PROBE_MARKER_EXPRESSION,
            WINE_PROBE_MARKER_EXPRESSION,
            LIVE_PROBE_MARKER_EXPRESSION,
        )
    }
    assert owners == {
        PURE_MARKER_EXPRESSION: {"test-harness.yml"},
        NATIVE_PROBE_MARKER_EXPRESSION: {"probe.yml"},
        # Wine and live integration remain explicit local opt-ins.
        WINE_PROBE_MARKER_EXPRESSION: set(),
        LIVE_PROBE_MARKER_EXPRESSION: set(),
    }
