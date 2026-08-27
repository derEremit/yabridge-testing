# Data Lifecycle and Performance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Create the isolated worktree with superpowers:using-git-worktrees at execution time (submodule `yabridge-test-infra`, branch `remediate/data-lifecycle`).

**Goal:** Version the results-server SQLite schema with Alembic, build the compatibility matrix in three queries instead of one per cell, and make `/api/v1/health` fail when SQLite cannot answer.

**Architecture:** A shared `build_matrix` issues two dimension aggregates plus one grouped cell aggregate, both public surfaces call it, and publication stays `published_criterion()`. Alembic owns schema: two handwritten revisions, a stamp-or-upgrade helper on boot, fixtures `create_all` then stamp head. Health runs `SELECT 1` and returns 503 on failure.

**Tech Stack:** Python 3.10+, FastAPI, SQLAlchemy 2, Alembic, pytest, aiosqlite, Fly.io SQLite.

**Spec:** `docs/superpowers/specs/2026-08-27-data-lifecycle-design.md`

## Global Constraints

- Single Fly machine, one SQLite file, one volume. No Postgres, Redis, login, or edge gateway.
- Do not change publication rules, CSP, quotas, or evidence storage.
- Do not enable WAL, a custom busy timeout, or `PRAGMA foreign_keys=ON`.
- Do not prune `screenshot_daily_usage`, drafts, or quarantined reports.
- Do not change startup evidence reconciliation (it still rehashes every blob).
- Do not migrate `TestResult.created_at` / `completed_at` to `UtcDateTime`.
- No revision in this phase `ALTER`s `test_results`.
- `Settings.from_env` remains the only environment loader. Do not invent settings keys.
- Commit all `yabridge-test-infra` changes in the submodule before the parent gitlink.
- Behavior changes follow witnessed red-green-refactor. Use `web/.venv/bin/python` (system Python 3.14 cannot collect this suite).
- Nothing is pushed unless asked.

## File structure

| File | Responsibility |
|---|---|
| `yabridge-test-infra/web/app/matrix.py` | Shared published matrix builder |
| `yabridge-test-infra/web/app/routes/matrix.py` | API uses the builder; stats unchanged |
| `yabridge-test-infra/web/app/main.py` | HTML matrix uses the builder; lifespan calls `apply_schema`; health queries SQLite |
| `yabridge-test-infra/web/app/schema.py` | Sync URL, stamp-or-upgrade, `stamp_head` |
| `yabridge-test-infra/web/alembic.ini` | Alembic config |
| `yabridge-test-infra/web/alembic/env.py` | Honors `sqlalchemy.url` already on the config |
| `yabridge-test-infra/web/alembic/versions/0001_legacy_baseline.py` | Four original tables |
| `yabridge-test-infra/web/alembic/versions/0002_phase3_additive.py` | Idempotent Phase 3 tables |
| `yabridge-test-infra/web/tests/conftest.py` | `create_all` then `stamp_head` before lifespan |
| `yabridge-test-infra/web/tests/test_matrix_aggregation.py` | Grouped-query and publication cell tests |
| `yabridge-test-infra/web/tests/test_health.py` | 200 connected / 503 disconnected |
| `yabridge-test-infra/web/tests/test_schema.py` | Stamp-or-upgrade cases |
| `yabridge-test-infra/web/requirements.txt` | Add `alembic` |
| `yabridge-test-infra/web/README.md` | Operator note: next boot migrates; do not delete the DB file |

Do not rewrite `publication.py`. Do not change `/api/v1/stats`.

---

### Task 1: Grouped matrix builder

**Files:**
- Create: `yabridge-test-infra/web/app/matrix.py`
- Create: `yabridge-test-infra/web/tests/test_matrix_aggregation.py`
- Modify: `yabridge-test-infra/web/app/routes/matrix.py`
- Modify: `yabridge-test-infra/web/app/main.py` (`matrix_page` only)

**Interfaces:**
- Consumes: `published_criterion()`, `TestResult` columns, `MatrixCell`
- Produces:

```python
@dataclass(frozen=True)
class MatrixGrid:
    rows: list[str]
    columns: list[str]
    cells: dict[str, dict[str, MatrixCell]]

DIMENSIONS: dict[str, InstrumentedAttribute[Any]]

async def build_matrix(
    db: AsyncSession,
    *,
    row_dimension: str,
    col_dimension: str,
    limit: int,
) -> MatrixGrid: ...

def cell_status(count: int, passed: int, failed: int) -> str: ...
```

- Unknown dimension names fall back to `wine_version` (rows) and `desktop` (columns), matching today's `dimension_map.get` behavior.
- Status: `count == 0` → `unknown`; `failed == 0` → `pass`; `passed == 0` → `fail`; else `partial`.
- Exactly three `execute` calls: row labels, column labels, grouped cells.

- [ ] **Step 1: Write the failing aggregation tests**

```python
# web/tests/test_matrix_aggregation.py
from __future__ import annotations

from typing import Any

import pytest
from sqlalchemy.ext.asyncio import AsyncSession

from app.matrix import build_matrix
from app.models import TestResult as StoredTestResult
from app.publication import PUBLISHED, QUARANTINED
from app.schemas import MatrixCell


def _row(
    *,
    wine: str,
    desktop: str,
    status: str,
    passed: int,
    failed: int,
) -> StoredTestResult:
    return StoredTestResult(
        publication_status=status,
        distro="Arch Linux",
        desktop=desktop,
        display_server="x11",
        wine_version=wine,
        yabridge_version="5.1.0",
        tests=[],
        workarounds=[],
        total_tests=passed + failed,
        passed_tests=passed,
        failed_tests=failed,
        skipped_tests=0,
        status="pass" if failed == 0 else "fail",
    )


class _CountingSession:
    def __init__(self, inner: AsyncSession) -> None:
        self._inner = inner
        self.calls = 0

    async def execute(self, statement: Any, *args: Any, **kwargs: Any) -> Any:
        self.calls += 1
        return await self._inner.execute(statement, *args, **kwargs)


@pytest.mark.asyncio
async def test_build_matrix_uses_three_queries_not_one_per_cell(
    db_session: AsyncSession,
) -> None:
    db_session.add_all(
        [
            _row(wine="wine-a", desktop="kde", status=PUBLISHED, passed=2, failed=0),
            _row(wine="wine-a", desktop="gnome", status=PUBLISHED, passed=0, failed=1),
            _row(wine="wine-b", desktop="kde", status=PUBLISHED, passed=1, failed=1),
            _row(wine="wine-b", desktop="gnome", status=PUBLISHED, passed=3, failed=0),
        ]
    )
    await db_session.commit()

    counted = _CountingSession(db_session)
    grid = await build_matrix(
        counted,  # type: ignore[arg-type]
        row_dimension="wine_version",
        col_dimension="desktop",
        limit=15,
    )

    assert counted.calls == 3
    assert grid.rows == ["wine-a", "wine-b"] or set(grid.rows) == {"wine-a", "wine-b"}
    assert set(grid.columns) == {"kde", "gnome"}
    assert grid.cells["wine-a"]["kde"].status == "pass"
    assert grid.cells["wine-a"]["kde"].pass_count == 2
    assert grid.cells["wine-a"]["kde"].total_count == 1
    assert grid.cells["wine-a"]["gnome"].status == "fail"
    assert grid.cells["wine-b"]["kde"].status == "partial"
    assert grid.cells["wine-b"]["gnome"].status == "pass"


@pytest.mark.asyncio
async def test_a_quarantined_report_does_not_move_a_published_cell(
    db_session: AsyncSession,
) -> None:
    db_session.add_all(
        [
            _row(wine="wine-a", desktop="kde", status=PUBLISHED, passed=2, failed=0),
            _row(wine="wine-a", desktop="kde", status=QUARANTINED, passed=0, failed=9),
        ]
    )
    await db_session.commit()

    grid = await build_matrix(
        db_session,
        row_dimension="wine_version",
        col_dimension="desktop",
        limit=15,
    )

    cell = grid.cells["wine-a"]["kde"]
    assert cell.status == "pass"
    assert cell.fail_count == 0
    assert cell.total_count == 1


@pytest.mark.asyncio
async def test_a_missing_intersection_is_unknown(
    db_session: AsyncSession,
) -> None:
    db_session.add_all(
        [
            _row(wine="wine-a", desktop="kde", status=PUBLISHED, passed=1, failed=0),
            _row(wine="wine-b", desktop="gnome", status=PUBLISHED, passed=1, failed=0),
        ]
    )
    await db_session.commit()

    grid = await build_matrix(
        db_session,
        row_dimension="wine_version",
        col_dimension="desktop",
        limit=15,
    )

    assert grid.cells["wine-a"]["gnome"] == MatrixCell(
        status="unknown",
        pass_count=0,
        fail_count=0,
        total_count=0,
        last_tested=None,
    )


@pytest.mark.asyncio
async def test_html_and_api_builders_agree_for_wine_by_desktop(
    db_session: AsyncSession,
) -> None:
    db_session.add(
        _row(wine="wine-10", desktop="KDE Plasma", status=PUBLISHED, passed=1, failed=0)
    )
    await db_session.commit()

    api = await build_matrix(
        db_session, row_dimension="wine_version", col_dimension="desktop", limit=15
    )
    html = await build_matrix(
        db_session, row_dimension="wine_version", col_dimension="desktop", limit=10
    )

    assert api.cells == html.cells
    assert api.rows == html.rows
    assert api.columns == html.columns
```

Fix the wine-a/wine-b row-order assertion before committing if frequency ties make order unstable: both wines have two published rows, so order is undefined. After you see the failure, pin expected `rows` with `assert set(grid.rows) == {"wine-a", "wine-b"}` only (already allowed above). Do not sort in production; keep today's `ORDER BY count DESC` and accept either order when counts tie.

- [ ] **Step 2: Run the tests and witness the import failure**

Run:

```bash
cd yabridge-test-infra/web
.venv/bin/python -m pytest -q tests/test_matrix_aggregation.py
```

Expected: `ImportError` / `ModuleNotFoundError` for `app.matrix`.

- [ ] **Step 3: Implement the builder and switch both surfaces**

```python
# web/app/matrix.py
from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from sqlalchemy import ColumnElement, func, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import InstrumentedAttribute

from .models import TestResult
from .publication import published_criterion
from .schemas import MatrixCell

DIMENSIONS: dict[str, InstrumentedAttribute[Any]] = {
    "wine_version": TestResult.wine_version,
    "desktop": TestResult.desktop,
    "host": TestResult.host,
    "display_server": TestResult.display_server,
    "distro": TestResult.distro,
}


@dataclass(frozen=True)
class MatrixGrid:
    rows: list[str]
    columns: list[str]
    cells: dict[str, dict[str, MatrixCell]]


def cell_status(count: int, passed: int, failed: int) -> str:
    if count == 0:
        return "unknown"
    if failed == 0:
        return "pass"
    if passed == 0:
        return "fail"
    return "partial"


async def _labels(
    db: AsyncSession, column: ColumnElement[Any], limit: int
) -> list[str]:
    statement = (
        select(column, func.count(TestResult.id))
        .where(column.isnot(None), published_criterion())
        .group_by(column)
        .order_by(func.count(TestResult.id).desc())
        .limit(limit)
    )
    result = await db.execute(statement)
    return [value for value, _count in result if value]


async def build_matrix(
    db: AsyncSession,
    *,
    row_dimension: str,
    col_dimension: str,
    limit: int,
) -> MatrixGrid:
    row_col = DIMENSIONS.get(row_dimension, TestResult.wine_version)
    col_col = DIMENSIONS.get(col_dimension, TestResult.desktop)
    rows = await _labels(db, row_col, limit)
    columns = await _labels(db, col_col, limit)

    cells: dict[str, dict[str, MatrixCell]] = {
        row: {
            column: MatrixCell(
                status="unknown",
                pass_count=0,
                fail_count=0,
                total_count=0,
                last_tested=None,
            )
            for column in columns
        }
        for row in rows
    }
    if not rows or not columns:
        return MatrixGrid(rows=rows, columns=columns, cells=cells)

    grouped = await db.execute(
        select(
            row_col,
            col_col,
            func.count(TestResult.id),
            func.sum(TestResult.passed_tests),
            func.sum(TestResult.failed_tests),
            func.max(TestResult.created_at),
        )
        .where(
            published_criterion(),
            row_col.in_(rows),
            col_col.in_(columns),
        )
        .group_by(row_col, col_col)
    )
    for row, column, count, passed, failed, last_tested in grouped:
        passed_i = int(passed or 0)
        failed_i = int(failed or 0)
        count_i = int(count or 0)
        cells[row][column] = MatrixCell(
            status=cell_status(count_i, passed_i, failed_i),
            pass_count=passed_i,
            fail_count=failed_i,
            total_count=count_i,
            last_tested=last_tested,
        )
    return MatrixGrid(rows=rows, columns=columns, cells=cells)
```

Replace the per-cell loops in `get_compatibility_matrix` with:

```python
from ..matrix import build_matrix

grid = await build_matrix(
    db,
    row_dimension=row_dimension,
    col_dimension=col_dimension,
    limit=limit,
)
return CompatibilityMatrixResponse(
    rows=grid.rows,
    columns=grid.columns,
    data=grid.cells,
    generated_at=datetime.now(timezone.utc),
)
```

Replace the per-cell loops in `matrix_page` with:

```python
from .matrix import build_matrix

grid = await build_matrix(
    db,
    row_dimension="wine_version",
    col_dimension="desktop",
    limit=10,
)
matrix_data = {
    wine: {
        desktop: {
            "status": cell.status,
            "count": cell.total_count,
            "passed": cell.pass_count,
            "failed": cell.fail_count,
        }
        for desktop, cell in columns.items()
    }
    for wine, columns in grid.cells.items()
}
# template context: wine_versions=grid.rows, desktops=grid.columns, matrix_data=matrix_data
```

Leave `get_stats` untouched.

- [ ] **Step 4: Run aggregation and publication-boundary matrix tests**

```bash
cd yabridge-test-infra/web
.venv/bin/python -m pytest -q tests/test_matrix_aggregation.py tests/test_publication_boundary.py
```

Expected: all pass. If `test_build_matrix_uses_three_queries_not_one_per_cell` fails on row order, weaken only the order assertion, not the query-count assertion.

- [ ] **Step 5: Commit**

```bash
cd yabridge-test-infra
git add web/app/matrix.py web/app/routes/matrix.py web/app/main.py web/tests/test_matrix_aggregation.py
git commit -m "$(cat <<'EOF'
feat: aggregate the compatibility matrix in one query

The API and HTML matrix were issuing one SELECT per cell. Both now
share a published-only grouped builder.
EOF
)"
```

---

### Task 2: Health check queries SQLite

**Files:**
- Create: `yabridge-test-infra/web/tests/test_health.py`
- Modify: `yabridge-test-infra/web/app/main.py` (`health` only)

**Interfaces:**
- Consumes: `request.app.state.session_factory`, `__version__`
- Produces: `GET /api/v1/health` → 200 `{"status":"healthy","version":...,"database":"connected"}` after `SELECT 1`; 503 `{"status":"unhealthy","version":...,"database":"disconnected"}` if execute raises
- Does not run evidence reconciliation. Does not attach write or aggregate quotas.

- [ ] **Step 1: Write the failing health tests**

```python
# web/tests/test_health.py
from __future__ import annotations

import pytest
from httpx import ASGITransport, AsyncClient

from app import __version__
from app.main import create_app
from app.settings import Settings


@pytest.mark.asyncio
async def test_health_reports_connected_after_select(
    client: AsyncClient,
) -> None:
    response = await client.get("/api/v1/health")

    assert response.status_code == 200
    assert response.json() == {
        "status": "healthy",
        "version": __version__,
        "database": "connected",
    }


@pytest.mark.asyncio
async def test_health_is_unhealthy_when_the_database_cannot_answer(
    test_settings: Settings,
) -> None:
    application = create_app(test_settings)

    class _DeadSession:
        async def execute(self, statement: object) -> None:
            raise RuntimeError("sqlite is down")

        async def __aenter__(self) -> _DeadSession:
            return self

        async def __aexit__(self, *args: object) -> None:
            return None

    class _DeadFactory:
        def __call__(self) -> _DeadSession:
            return _DeadSession()

    application.state.session_factory = _DeadFactory()

    transport = ASGITransport(app=application)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        response = await client.get("/api/v1/health")

    assert response.status_code == 503
    body = response.json()
    assert body["status"] == "unhealthy"
    assert body["database"] == "disconnected"
    assert body["version"] == __version__
    assert "connected" not in body.values()
```

The 503 test must not enter lifespan if that would require a real schema; `create_app` currently starts an engine but `health` only needs `session_factory` on state. Do not wrap this client in `lifespan_context` unless `health` cannot be reached otherwise. If ASGI routing requires the app object only, this is enough.

- [ ] **Step 2: Run the tests and witness the 503 failure**

```bash
cd yabridge-test-infra/web
.venv/bin/python -m pytest -q tests/test_health.py
```

Expected: connected path already passes; disconnected path fails because `health` never opens a session (200 + `"connected"`).

- [ ] **Step 3: Query SQLite in `health`**

Replace `health` in `web/app/main.py`:

```python
from fastapi.responses import JSONResponse
from sqlalchemy import text

@frontend_router.get("/api/v1/health")
async def health(request: Request) -> JSONResponse:
    """Fly probes this path. Claim a connection only after SQLite answers."""
    try:
        async with request.app.state.session_factory() as session:
            await session.execute(text("SELECT 1"))
    except Exception:
        return JSONResponse(
            {
                "status": "unhealthy",
                "version": __version__,
                "database": "disconnected",
            },
            status_code=503,
        )
    return JSONResponse(
        {
            "status": "healthy",
            "version": __version__,
            "database": "connected",
        }
    )
```

Do not add quota dependencies. Do not call `reconcile_evidence_storage`.

- [ ] **Step 4: Re-run health plus existing header hits**

```bash
cd yabridge-test-infra/web
.venv/bin/python -m pytest -q tests/test_health.py tests/test_security_headers.py tests/test_quota_routes.py tests/test_app_factory.py
```

Expected: all pass. Header tests still `GET /api/v1/health` on a live fixture (200).

- [ ] **Step 5: Commit**

```bash
cd yabridge-test-infra
git add web/app/main.py web/tests/test_health.py
git commit -m "$(cat <<'EOF'
fix: make the health probe require a live database

Fly already hits /api/v1/health. The handler now runs SELECT 1 and
returns 503 when SQLite does not answer, instead of claiming connected.
EOF
)"
```

---

### Task 3: Alembic revisions and stamp-or-upgrade helper

**Files:**
- Create: `yabridge-test-infra/web/app/schema.py`
- Create: `yabridge-test-infra/web/alembic.ini`
- Create: `yabridge-test-infra/web/alembic/env.py`
- Create: `yabridge-test-infra/web/alembic/script.py.mako`
- Create: `yabridge-test-infra/web/alembic/versions/0001_legacy_baseline.py`
- Create: `yabridge-test-infra/web/alembic/versions/0002_phase3_additive.py`
- Create: `yabridge-test-infra/web/tests/test_schema.py`
- Modify: `yabridge-test-infra/web/requirements.txt` (add `alembic`)

**Interfaces:**
- Consumes: `Settings.database_url`, `Base.metadata` for the contract test
- Produces:

```python
LEGACY_REVISION = "0001_legacy_baseline"

class SchemaDecisionError(RuntimeError): ...

def sync_sqlite_url(database_url: str) -> str: ...
def stamp_head(database_url: str) -> None: ...
def apply_schema(database_url: str) -> None: ...
```

- `sync_sqlite_url("sqlite+aiosqlite:////data/yabridge_tests.db")` → `"sqlite:////data/yabridge_tests.db"`
- `sync_sqlite_url("sqlite:////tmp/test.db")` is unchanged
- `apply_schema` decision, in this order:
  1. `alembic_version` table exists → `upgrade head`
  2. no user tables (ignore `sqlite_sequence`) → `upgrade head`
  3. `test_results` exists and `alembic_version` does not → `stamp` `0001_legacy_baseline`, then `upgrade head`
  4. anything else → raise `SchemaDecisionError`
- Revision 2 is idempotent (`CREATE` only when the table/index is missing).
- Do not replace `create_all` in lifespan in this task.

Install Alembic before the tests can import the helper:

```bash
cd yabridge-test-infra/web
.venv/bin/python -m pip install 'alembic>=1.13'
```

Add `alembic>=1.13` to `requirements.txt` in the same commit as the helper.

- [ ] **Step 1: Write the failing schema tests**

```python
# web/tests/test_schema.py
from __future__ import annotations

from pathlib import Path

import pytest
from sqlalchemy import create_engine, inspect, text
from sqlalchemy.orm import Session, sessionmaker

from app.models import Base, Plugin
from app.schema import LEGACY_REVISION, SchemaDecisionError, apply_schema, sync_sqlite_url


def _url(path: Path) -> str:
    return f"sqlite:///{path}"


def _tables(url: str) -> set[str]:
    engine = create_engine(url)
    try:
        return set(inspect(engine).get_table_names())
    finally:
        engine.dispose()


def _columns(url: str, table: str) -> set[str]:
    engine = create_engine(url)
    try:
        return {column["name"] for column in inspect(engine).get_columns(table)}
    finally:
        engine.dispose()


def test_sync_sqlite_url_strips_the_async_driver() -> None:
    assert (
        sync_sqlite_url("sqlite+aiosqlite:////data/yabridge_tests.db")
        == "sqlite:////data/yabridge_tests.db"
    )
    assert sync_sqlite_url("sqlite:////tmp/test.db") == "sqlite:////tmp/test.db"


def test_an_empty_file_upgraded_to_head_matches_the_models(tmp_path: Path) -> None:
    url = _url(tmp_path / "empty.db")
    apply_schema(url)

    assert _tables(url) - {"alembic_version", "sqlite_sequence"} == set(
        Base.metadata.tables
    )
    for name, table in Base.metadata.tables.items():
        assert {column.name for column in table.columns} <= _columns(url, name)


def test_a_create_all_database_stamps_and_keeps_rows(tmp_path: Path) -> None:
    url = _url(tmp_path / "phase3.db")
    engine = create_engine(url)
    Base.metadata.create_all(engine)
    with Session(engine) as session:
        session.add(Plugin(name="Serum", vendor="Xfer", plugin_type="vst3"))
        session.commit()
    engine.dispose()

    apply_schema(url)

    engine = create_engine(url)
    with engine.connect() as connection:
        version = connection.execute(text("SELECT version_num FROM alembic_version")).scalar_one()
        names = connection.execute(text("SELECT name FROM plugins")).scalars().all()
    engine.dispose()

    assert "moderation_audits" in _tables(url)
    assert names == ["Serum"]
    from alembic.config import Config
    from alembic.script import ScriptDirectory

    from app.schema import alembic_config

    head = ScriptDirectory.from_config(alembic_config(url)).get_current_head()
    assert version == head


def test_a_legacy_file_gains_phase3_tables(tmp_path: Path) -> None:
    url = _url(tmp_path / "legacy.db")
    apply_schema(url)
    engine = create_engine(url)
    with engine.connect() as connection:
        connection.execute(text("DELETE FROM alembic_version"))
        connection.execute(text("DROP TABLE alembic_version"))
        for table in (
            "screenshot_evidence",
            "screenshot_blobs",
            "screenshot_daily_usage",
            "evidence_storage_state",
            "moderation_audits",
            "rate_limit_buckets",
            "test_result_environments",
        ):
            connection.execute(text(f"DROP TABLE {table}"))
        connection.commit()
    engine.dispose()

    assert "moderation_audits" not in _tables(url)
    apply_schema(url)
    assert "moderation_audits" in _tables(url)
    assert "rate_limit_buckets" in _tables(url)


def test_an_unexpected_schema_is_refused(tmp_path: Path) -> None:
    url = _url(tmp_path / "odd.db")
    engine = create_engine(url)
    with engine.connect() as connection:
        connection.execute(text("CREATE TABLE leftover (id INTEGER PRIMARY KEY)"))
        connection.commit()
    engine.dispose()

    with pytest.raises(SchemaDecisionError):
        apply_schema(url)
```

The legacy-file test builds a true revision-1 shape by upgrading to head, then dropping revision-2 tables and `alembic_version`. That is allowed: Task 3 implements both revisions together, so the test can use the helper to construct the pre-Alembic Fly shape.

- [ ] **Step 2: Run the tests and witness the import failure**

```bash
cd yabridge-test-infra/web
.venv/bin/python -m pytest -q tests/test_schema.py
```

Expected: `ModuleNotFoundError: app.schema` (or Alembic missing if you have not installed it yet).

- [ ] **Step 3: Add Alembic config, revisions, and the helper**

`web/alembic.ini`:

```ini
[alembic]
script_location = alembic
prepend_sys_path = .
version_path_separator = os

[loggers]
keys = root,sqlalchemy,alembic

[handlers]
keys = console

[formatters]
keys = generic

[logger_root]
level = WARN
handlers = console
qualname =

[logger_sqlalchemy]
level = WARN
handlers =
qualname = sqlalchemy.engine

[logger_alembic]
level = INFO
handlers =
qualname = alembic

[handler_console]
class = StreamHandler
args = (sys.stderr,)
level = NOTSET
formatter = generic

[formatter_generic]
format = %(levelname)-5.5s [%(name)s] %(message)s
```

`web/alembic/env.py`:

```python
from logging.config import fileConfig

from alembic import context
from sqlalchemy import engine_from_config, pool

from app.models import Base
from app.schema import sync_sqlite_url
from app.settings import Settings

config = context.config
if config.config_file_name is not None:
    fileConfig(config.config_file_name)

if not config.get_main_option("sqlalchemy.url"):
    config.set_main_option(
        "sqlalchemy.url", sync_sqlite_url(Settings.from_env().database_url)
    )

target_metadata = Base.metadata


def run_migrations_offline() -> None:
    url = config.get_main_option("sqlalchemy.url")
    context.configure(url=url, target_metadata=target_metadata, literal_binds=True)
    with context.begin_transaction():
        context.run_migrations()


def run_migrations_online() -> None:
    connectable = engine_from_config(
        config.get_section(config.config_ini_section, {}),
        prefix="sqlalchemy.",
        poolclass=pool.NullPool,
    )
    with connectable.connect() as connection:
        context.configure(connection=connection, target_metadata=target_metadata)
        with context.begin_transaction():
            context.run_migrations()


if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()
```

`web/alembic/script.py.mako` — Alembic's default template (revision/down_revision/upgrade/downgrade). Copy the stock file Alembic writes when you run `alembic init` if you prefer; do not leave it empty.

`web/app/schema.py`:

```python
from __future__ import annotations

from pathlib import Path

from alembic import command
from alembic.config import Config
from sqlalchemy import create_engine, inspect

WEB_ROOT = Path(__file__).resolve().parent.parent
LEGACY_REVISION = "0001_legacy_baseline"
_INTERNAL_TABLES = frozenset({"sqlite_sequence"})


class SchemaDecisionError(RuntimeError):
    """The file is neither empty, versioned, nor a known pre-Alembic results DB."""


def sync_sqlite_url(database_url: str) -> str:
    return database_url.replace("sqlite+aiosqlite://", "sqlite://", 1)


def alembic_config(database_url: str) -> Config:
    config = Config(str(WEB_ROOT / "alembic.ini"))
    config.set_main_option("script_location", str(WEB_ROOT / "alembic"))
    config.set_main_option("sqlalchemy.url", sync_sqlite_url(database_url))
    return config


def stamp_head(database_url: str) -> None:
    command.stamp(alembic_config(database_url), "head")


def apply_schema(database_url: str) -> None:
    url = sync_sqlite_url(database_url)
    engine = create_engine(url)
    try:
        tables = set(inspect(engine).get_table_names())
    finally:
        engine.dispose()

    config = alembic_config(url)
    if "alembic_version" in tables:
        command.upgrade(config, "head")
        return

    user_tables = tables - _INTERNAL_TABLES
    if not user_tables:
        command.upgrade(config, "head")
        return

    if "test_results" in user_tables:
        command.stamp(config, LEGACY_REVISION)
        command.upgrade(config, "head")
        return

    raise SchemaDecisionError(
        "database is not empty, not versioned, and has no test_results table"
    )
```

Revision 1 — `web/alembic/versions/0001_legacy_baseline.py`. `revision = "0001_legacy_baseline"`, `down_revision = None`. In `upgrade()`, `op.create_table` for `plugins`, `hosts`, `test_results`, then `tested_plugins` (FKs need `test_results` and `plugins` first). Columns for `test_results` must be every column on today's `TestResult` model:

`id`, `created_at`, `publication_status`, `completion_token`, `completed_at`, `overall_result`, `user_notes`, `issues_observed`, `workarounds_tried`, `distro`, `kernel`, `desktop`, `desktop_version`, `display_server`, `compositor`, `wine_version`, `wine_staging`, `wine_patches`, `wine_variant`, `wine_prefix`, `wine_dpi`, `yabridge_version`, `yabridge_commit`, `yabridge_branch`, `dpi_scale`, `monitors`, `cpu`, `gpu`, `gpu_driver`, `ram_gb`, `host`, `host_version`, `plugin_name`, `plugin_type`, `plugin_vendor`, `plugin_version`, `tests`, `total_tests`, `passed_tests`, `failed_tests`, `skipped_tests`, `status`, `workarounds`, `notes`, `logs`, `submitter`, `submitter_contact`, `report_timestamp`.

Use `sa.Integer`, `sa.String(n)`, `sa.Text`, `sa.Boolean`, `sa.Float`, `sa.DateTime`, `sa.JSON`. Unique index on `completion_token`. `downgrade()` drops `tested_plugins`, `test_results`, `hosts`, `plugins`.

Revision 2 — `web/alembic/versions/0002_phase3_additive.py`. `revision = "0002_phase3_additive"`, `down_revision = "0001_legacy_baseline"`. In `upgrade()`, `bind = op.get_bind()`, `inspector = inspect(bind)`, `existing = set(inspector.get_table_names())`. For each of `test_result_environments`, `screenshot_blobs`, `screenshot_evidence`, `screenshot_daily_usage`, `evidence_storage_state`, `moderation_audits`, `rate_limit_buckets`: create only if missing. Constraints from the spec:

- `test_result_environments`: PK `result_id`, FK → `test_results.id` ON DELETE CASCADE, `xwayland_available` Boolean not null default false
- `screenshot_blobs`: PK `sha256` String(64), `media_type`, `extension`, `byte_size`, `width`, `height`, `created_at` DateTime not null
- `screenshot_evidence`: PK `id`, FKs to result (CASCADE) and `screenshot_blobs.sha256`, unique `(result_id, position)`, check `position >= 0`
- `screenshot_daily_usage`: PK `(subject, day_start)`, `accepted_bytes`
- `evidence_storage_state`: PK `id`, `unique_screenshot_bytes`
- `moderation_audits`: PK `id`, FK `result_id` CASCADE, `actor_key_id`, `actor_key_digest`, `action`, `reason`, `created_at`
- `rate_limit_buckets`: PK `(subject, route_group, window_seconds, window_start)`, `expires_at`, `request_count`, `accepted_body_bytes`; create index `ix_rate_limit_buckets_expires_at` only if missing (`inspector.get_indexes("rate_limit_buckets")`)

`downgrade()` drops those seven tables (evidence before blobs).

Write the revision files in full in the implementation commit. Do not autogenerate them from a live database.

- [ ] **Step 4: Run the schema tests**

```bash
cd yabridge-test-infra/web
.venv/bin/python -m pytest -q tests/test_schema.py
```

Expected: pass. If `test_an_empty_file_upgraded_to_head_matches_the_models` fails on extra Alembic-only columns, the assertion is already `model columns ⊆ migrated columns`. If a model table is missing, the revision is incomplete — add the table, do not weaken the test.

- [ ] **Step 5: Commit**

```bash
cd yabridge-test-infra
git add web/app/schema.py web/alembic.ini web/alembic web/tests/test_schema.py web/requirements.txt
git commit -m "$(cat <<'EOF'
feat: version the results-server schema with Alembic

Startup can now stamp a pre-Alembic SQLite file and upgrade it. The
revisions match today's models so later phases can ALTER columns.
EOF
)"
```

---

### Task 4: Boot migrations, fixture stamp, operator docs

**Files:**
- Modify: `yabridge-test-infra/web/app/main.py` (lifespan only)
- Modify: `yabridge-test-infra/web/tests/conftest.py`
- Modify: `yabridge-test-infra/web/tests/test_moderation_audit_table.py` (docstring of `test_the_audit_table_is_created_by_the_normal_startup_path`)
- Modify: `yabridge-test-infra/web/tests/test_schema.py` (add the `create_app` empty-file test)
- Modify: `yabridge-test-infra/web/README.md`
- Modify: `yabridge-test-infra/docs/architecture.md` only if the security section still says schema is `create_all` with no migrations — add one sentence that boot runs Alembic. Do not rewrite the chapter.

**Interfaces:**
- Consumes: `apply_schema`, `stamp_head` from Task 3
- Produces: production lifespan calls `apply_schema(app_settings.database_url)` instead of `Base.metadata.create_all`. Fixtures `create_all` then `stamp_head` so lifespan upgrade is a no-op.

- [ ] **Step 1: Write the failing production-path test**

Add to `web/tests/test_schema.py`:

```python
import pytest
from sqlalchemy import inspect

from app.main import create_app
from app.settings import Settings


@pytest.mark.asyncio
async def test_create_app_migrates_an_empty_database(tmp_path: Path) -> None:
    settings = Settings(
        database_url=f"sqlite:///{tmp_path / 'fresh.db'}",
        public_base_url="http://test",
        screenshot_dir=tmp_path / "screenshots",
        client_identity_secret="test-only-identity-secret-value",
    )
    (tmp_path / "screenshots").mkdir()
    application = create_app(settings)
    async with application.router.lifespan_context(application):
        async with application.state.engine.connect() as connection:
            tables = await connection.run_sync(lambda sync: set(inspect(sync).get_table_names()))

    assert "alembic_version" in tables
    assert "moderation_audits" in tables
    assert "test_results" in tables
```

This test must not use the `app` fixture (that fixture will stamp). It boots `create_app` on an empty file the way Fly will.

- [ ] **Step 2: Run it and witness create_all-without-version**

```bash
cd yabridge-test-infra/web
.venv/bin/python -m pytest -q tests/test_schema.py::test_create_app_migrates_an_empty_database
```

Expected: fail because lifespan still `create_all`s and never writes `alembic_version`.

- [ ] **Step 3: Switch lifespan and fixtures**

In `create_app` lifespan, replace:

```python
async with engine.begin() as connection:
    await connection.run_sync(Base.metadata.create_all)
```

with:

```python
from .schema import apply_schema

apply_schema(app_settings.database_url)
```

Keep evidence reconciliation after that, still fatal.

In `web/tests/conftest.py`:

```python
from sqlalchemy import create_engine

from app.models import Base
from app.schema import stamp_head, sync_sqlite_url


@pytest.fixture
async def app(test_settings: Settings) -> AsyncIterator[FastAPI]:
    engine = create_engine(sync_sqlite_url(test_settings.database_url))
    Base.metadata.create_all(engine)
    engine.dispose()
    stamp_head(test_settings.database_url)
    application = create_app(test_settings)
    async with application.router.lifespan_context(application):
        yield application
```

Update the audit-table test docstring from "the existing `create_all` covers it" to "startup migrations create it". The assertion (`moderation_audits` in tables) stays.

README — add a short section after Environment (do not invent settings keys):

```markdown
## Schema

The process runs Alembic on startup. A brand-new `DATABASE_URL` file is
created at head. A pre-Alembic file that already has `test_results` is
stamped as the legacy baseline and then upgraded. Do not delete the
SQLite file to "install" migrations. `alembic` is a runtime dependency
because the app applies revisions itself; it is not a laptop-only tool.
```

- [ ] **Step 4: Run schema, docs, and a slice of the web suite**

```bash
cd yabridge-test-infra/web
.venv/bin/python -m pytest -q tests/test_schema.py tests/test_operations_docs.py tests/test_moderation_audit_table.py tests/test_health.py tests/test_matrix_aggregation.py
```

Expected: pass. `test_operations_readme_does_not_invent_settings_keys` still passes (the new section names only `DATABASE_URL`).

Then:

```bash
cd yabridge-test-infra/web
.venv/bin/python -m pytest -q
.venv/bin/python -m mypy app
.venv/bin/python -m ruff check app tests
```

Expected: full suite green, mypy clean, ruff clean.

- [ ] **Step 5: Commit**

```bash
cd yabridge-test-infra
git add web/app/main.py web/tests/conftest.py web/tests/test_schema.py web/tests/test_moderation_audit_table.py web/README.md web/docs/architecture.md
git commit -m "$(cat <<'EOF'
feat: apply Alembic on results-server startup

create_all no longer owns production schema. Boot stamps or upgrades
the SQLite file; tests still create_all and stamp head so the suite
does not replay history on every case.
EOF
)"
```

Only add `docs/architecture.md` if you actually edited it.

---

### Task 5: Verify merged work and record the parent gitlink

**Files:**
- Modify: parent `yabridge-test-infra` gitlink
- Modify: parent `README.md` only if the results-server pointer should mention migrations (optional; the existing `web/README.md` link is enough)

**Interfaces:**
- Consumes: submodule HEAD after Tasks 1–4
- Produces: parent commit pointing at that HEAD. No push.

- [ ] **Step 1: Verify the submodule worktree**

```bash
cd yabridge-test-infra/web
.venv/bin/python -m pytest -q
.venv/bin/python -m mypy app
.venv/bin/python -m ruff check app tests
```

Expected: full suite pass, mypy clean, ruff clean. Confirm `create_all` is gone from `app/main.py` and present only in `tests/conftest.py` plus `tests/test_schema.py`.

- [ ] **Step 2: Merge the feature branch into submodule `main` locally**

Use the finishing-a-development-branch skill. Default base is `yabridge-test-infra` `main`. Do not push.

- [ ] **Step 3: Re-verify on merged submodule `main`**

Same three commands as Step 1, from the submodule checkout (not only the worktree). Install `alembic` into that checkout's `web/.venv` if it is missing.

- [ ] **Step 4: Parent integration**

```bash
cd /home/z3n/projects/yabridge-staging
bats tests/setup_harness.bats
```

Expected: 3 passed. If `TMPDIR` is unwritable, use the default `/tmp`.

- [ ] **Step 5: Record the gitlink and clean up**

```bash
cd /home/z3n/projects/yabridge-staging
git add yabridge-test-infra
git commit -m "$(cat <<'EOF'
feat: record data lifecycle remediation

Point the submodule at Alembic-backed schema, grouped matrix queries,
and a health check that actually reaches SQLite.
EOF
)"
```

Remove the feature worktree and delete `remediate/data-lifecycle` only after merged verification is green, per finishing-a-development-branch. Do not push.

---

## Self-review

**Spec coverage**

| Spec requirement | Task |
|---|---|
| Grouped matrix for API and HTML | 1 |
| Publication filter unchanged; empty cell `unknown`; quarantined rows ignored | 1 |
| API/HTML builder agreement | 1 |
| `/api/v1/stats` unchanged | 1 (explicit non-touch) |
| Health `SELECT 1` / 503 | 2 |
| Two handwritten revisions, no `test_results` ALTER | 3 |
| Idempotent revision 2 | 3 |
| Stamp-or-upgrade decision order and refusal | 3 |
| Empty / create_all / legacy / unexpected tests | 3 |
| Lifespan uses helper; fixtures stamp; README | 4 |
| `create_all` gone from production lifespan | 4 |
| Parent gitlink, no push | 5 |
| WAL / FK / pruning / reconciliation out of scope | Global constraints |

**Placeholders:** none. Revision 2 column lists are specified; the implementer writes the `op.create_table` calls in Task 3 Step 3 rather than autogenerating.

**Types:** `MatrixGrid`, `build_matrix`, `apply_schema`, `stamp_head`, `sync_sqlite_url`, `SchemaDecisionError`, `LEGACY_REVISION` are named the same in every task that uses them.
