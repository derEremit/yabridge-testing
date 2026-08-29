"""Build an isolated-DAW draft from environment + run-manifest scalars."""

from __future__ import annotations

import os
from pathlib import Path

from .environment import collect_environment
from .provenance import load_session_scalars, resolve_test_root
from .schemas import TestReport


def build_session_report(
    *,
    notes: str | None = None,
    test_root: Path | None = None,
) -> TestReport:
    """Collect environment and overlay public-safe run-manifest scalars.

    No manifest path fields are copied. ``session_type`` is ``isolated-daw``.
    """
    root = test_root if test_root is not None else resolve_test_root(os.environ)
    env = collect_environment()
    scalars = load_session_scalars(root) if root is not None else None

    if scalars is not None:
        updates: dict[str, object] = {}
        if scalars.wine_version:
            updates["wine_version"] = scalars.wine_version
        if scalars.wine_sha256:
            updates["wine_sha256"] = scalars.wine_sha256
        if scalars.wine_digest_verified is not None:
            updates["wine_digest_verified"] = scalars.wine_digest_verified
        if scalars.yabridge_commit:
            updates["yabridge_commit"] = scalars.yabridge_commit
        if scalars.yabridge_ref:
            updates["yabridge_branch"] = scalars.yabridge_ref
        if updates:
            env = env.model_copy(update=updates)

    return TestReport(
        environment=env,
        host=scalars.host if scalars is not None else None,
        notes=notes,
        session_type="isolated-daw",
        tests=[],
    )
