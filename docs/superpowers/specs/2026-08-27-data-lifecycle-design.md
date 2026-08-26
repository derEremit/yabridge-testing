# Data lifecycle and performance design

Date: 2026-08-27

This is Phase 4 of
[`2026-08-25-yabridge-staging-remediation-design.md`](2026-08-25-yabridge-staging-remediation-design.md).
It covers only the Phase 4 items that Phase 3 did not already ship.

## Goal

Give the results server a versioned schema path, stop the compatibility matrix
from issuing one SQL query per cell, and make Fly's health probe fail when
SQLite is not actually reachable.

The deployment stays one Fly machine, one SQLite file, one volume. No Postgres,
Redis, login, or edge gateway.

## Already done (do not redo)

Phase 3 shipped a single publication policy in `web/app/publication.py`.
`published_criterion()` already scopes list, detail, HTML pages, matrix,
statistics, and evidence. Direct submissions and completed drafts publish
immediately. Drafts stay `draft` until completion. Moderation is the only
non-public listing. Boundary tests already lock this down.

Those bullets from the parent remediation spec are closed.

## Out of scope

Leave these deferred. They are real, but they are not this phase:

- `PRAGMA journal_mode=WAL` and an explicit busy timeout
- `PRAGMA foreign_keys=ON` at runtime
- Pruning `screenshot_daily_usage`, drafts, or quarantined reports
- Cheaper startup evidence reconciliation (it still rehashes every blob)
- Migrating `TestResult.created_at` / `completed_at` to `UtcDateTime`
- Changing publication rules, CSP, quotas, or evidence storage

## Alembic

Alembic is SQLAlchemy's migration tool: a numbered list of schema changes the
app applies to the SQLite file on startup. `Base.metadata.create_all` only
creates missing **tables**. It will never `ALTER` an existing table. That is
why Phase 3 could add new tables and could not change columns on
`test_results`. Alembic is how later phases change columns without deleting
`/data/yabridge_tests.db`.

### Layout

Work lives in the `yabridge-test-infra` submodule:

- `web/alembic.ini`
- `web/alembic/env.py` (reads the same `DATABASE_URL` as `Settings.from_env`)
- `web/alembic/versions/`
- `web/app/schema.py` — stamp-or-upgrade helper called from `create_app` lifespan

Add `alembic` to `web/requirements.txt`. Convert
`sqlite+aiosqlite:///...` to a sync `sqlite:///...` URL for Alembic. Do not
introduce a second settings loader.

### Revisions

Two revisions, written by hand against the current models. Do not autogenerate
the first pair from a live database of unknown vintage.

**Revision 1 — `0001_legacy_baseline`.** Create the four tables that existed in
the initial web commit (`d34134b`):

| Table | Notes |
|---|---|
| `plugins` | id, name, vendor, plugin_type, usage_count, created_at |
| `hosts` | id, name, usage_count, created_at |
| `tested_plugins` | id, result_id, plugin_id, plugin_name, plugin_type, plugin_status |
| `test_results` | Every column on today's `TestResult` model. Those columns were already present at the initial commit, including `publication_status`, `completion_token`, and `completed_at`. |

**Revision 2 — `0002_phase3_additive`.** Create the Phase 3 tables that
`create_all` currently adds:

| Table | Required constraints |
|---|---|
| `test_result_environments` | PK `result_id` FK → `test_results.id` ON DELETE CASCADE |
| `screenshot_blobs` | PK `sha256` |
| `screenshot_evidence` | unique `(result_id, position)`, `position >= 0`, FKs to result and blob |
| `screenshot_daily_usage` | PK `(subject, day_start)` |
| `evidence_storage_state` | PK `id` |
| `moderation_audits` | FK `result_id` ON DELETE CASCADE |
| `rate_limit_buckets` | composite PK plus index `ix_rate_limit_buckets_expires_at` |

Revision 2 must be idempotent on SQLite: `CREATE TABLE IF NOT EXISTS` and
create the named index only if it is missing. A Phase 3 deployment that already
ran `create_all` must survive `upgrade` without error and without dropping
rows.

No revision in this phase `ALTER`s `test_results`. There is no missing column
on that table today. Alembic's job this phase is to take ownership of the
schema so a later revision *can* alter it.

### Startup

Replace `await connection.run_sync(Base.metadata.create_all)` in `create_app`
lifespan with the helper. Decision, in this order:

1. If `alembic_version` exists → `upgrade head`.
2. If the database has no user tables (empty file or only SQLite internals) →
   `upgrade head` (runs 1 then 2).
3. If `test_results` exists and `alembic_version` does not → stamp revision 1,
   then `upgrade head` (runs 2 only). That is the pre-Alembic Fly file.

If the helper cannot decide (unexpected tables, no `test_results`, no version),
startup fails. Do not guess and do not fall back to `create_all`.

Migration failure is fatal, same as a missing screenshot blob at
reconciliation. The process must not serve traffic on a schema it could not
bring to head.

Tests keep `create_all` in fixtures so the suite stays fast. After
`create_all`, the fixture stamps head so the lifespan helper sees a versioned
database and `upgrade` is a no-op. The dedicated Alembic tests below exercise
the helper on their own temp files and do not go through that shortcut.

### Tests that Alembic must have

- An empty temp file upgraded to head has the same table names and column
  names as `Base.metadata`.
- A temp file built with `create_all` (today's Phase 3 shape) then passed
  through the helper ends at head, keeps its rows, and does not raise.
- A temp file that has only revision 1 tables, no `alembic_version`, then
  passed through the helper gains the revision 2 tables and is at head.
- An unexpected schema (for example a lone unrelated table) makes the helper
  raise.

### Operator notes

Document in `web/README.md`:

- Next boot applies migrations. Do not delete the SQLite file to "install"
  Alembic.
- `SCREENSHOT_DIR` stays a subdirectory of `/data`. The database file stays
  where `DATABASE_URL` already points.
- `alembic` is a runtime dependency because the app runs it on startup, not a
  laptop-only tool.

## Matrix aggregation

`GET /api/v1/matrix` and HTML `GET /matrix` both issue two dimension queries
and then one aggregate per cell. Default API limits are 15×15 (227 queries).
The HTML page is wine×desktop at 10×10 (102 queries).

Put one builder in `web/app/matrix.py`, used by both surfaces:

1. Published-only `GROUP BY` for the row labels, limited and ordered by count
   descending (same as today).
2. Same for column labels.
3. One published-only `GROUP BY row_col, col_col` that returns
   `COUNT(id)`, `SUM(passed_tests)`, `SUM(failed_tests)`, and `MAX(created_at)`,
   restricted to the chosen label sets.

Map those rows into the existing `MatrixCell` / template dict. A missing
intersection is `unknown` with zero counts. Status stays:

- `count == 0` → `unknown`
- `failed == 0` → `pass`
- `passed == 0` → `fail`
- otherwise → `partial`

The HTML page keeps wine×desktop and limit 10. The API keeps its dimension
query parameters and default limit 15. `published_criterion()` stays the only
publication filter.

Do not change `/api/v1/stats`. It is already grouped and published-only.

### Tests

Existing publication-boundary matrix tests stay and must keep passing.

Add tests that:

- A cell's counts match a single grouped query, not N+1 (assert the builder
  does not execute a per-cell `SELECT` inside the row/column loops).
- A quarantined report that shares a published cell's coordinates does not
  change that cell.
- Empty intersections remain `unknown`.
- API and HTML builder results agree for wine×desktop on the same data.

## Health check

`GET /api/v1/health` currently returns 200 and `"database": "connected"`
without opening a session. Fly already probes this path
(`web/fly.toml`, 5s timeout, 30s interval, 10s grace).

Use the app `session_factory`, execute `SELECT 1`, and only then return 200:

```json
{"status": "healthy", "version": "<app version>", "database": "connected"}
```

If the query raises, return 503:

```json
{"status": "unhealthy", "version": "<app version>", "database": "disconnected"}
```

Do not run evidence reconciliation on this path. Do not attach write or
aggregate quotas. Existing header tests that `GET` health stay on the 200
path.

Add a test that a session factory whose execute raises produces 503 and never
claims `"connected"`.

## Repository boundary

All code, migrations, and web tests land in `yabridge-test-infra` first. The
parent repository only records the new submodule gitlink and, if needed, a
pointer in the root README. Nothing is pushed unless asked.

## Success criteria

- A pre-Alembic SQLite file that already has `test_results` reaches head on
  boot without data loss.
- A brand-new file reaches the same head.
- `create_all` is gone from production lifespan.
- API and HTML matrix each use one cell aggregate query, not one per cell.
- Public matrix numbers still ignore unpublished rows.
- Fly's health probe gets 503 when SQLite cannot answer `SELECT 1`.
- WAL, foreign keys, pruning, and reconciliation cost are unchanged.
