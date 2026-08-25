# Harness Correctness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Python harness produce enforceable results and replace its tautological global-pointer check with a deterministic CLAP plugin whose Wine child window reports the coordinates it actually receives through yabridge.

**Architecture:** First establish a conventional, strict Python test boundary and centralize result semantics. Then derive environment and bridge identity from staging provenance instead of guesses. Finally add a pure-Python probe protocol/evaluator, a pinned C CLAP probe plugin plus Linux host, and wire the measured bridged result into the CLI, reports, CI, and root submodule pointer.

**Tech Stack:** Python 3.10+, pytest, Click, Pydantic v2, Meson, C99, CLAP 1.1.9, MinGW-w64, Xlib/XTest, Wine, yabridge, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-08-25-yabridge-staging-remediation-design.md`

## Global Constraints

- Commit all `yabridge-test-infra` changes in the submodule before committing the parent repository's updated gitlink.
- Behavior changes follow witnessed red-green-refactor cycles.
- Unit tests must not require a desktop, Wine prefix, network, production plugin path, or production yabridge configuration.
- Integration tests use only temporary Wine prefixes, X displays, plugin fixtures, and reporting endpoints.
- `FAIL`, `ERROR`, empty execution, and failed submission are unsuccessful CLI outcomes.
- Staging provenance is parsed as data; component state and JSON are never sourced or evaluated.
- A bridge is identified by canonical metadata targets and managed bridge roots, never by assuming a `.so` beside a Windows plugin.
- Native Wayland session type and XWayland availability are separate facts.
- The coordinate verdict comes from a Wine child window reached through yabridge; global-pointer round trips may only be prerequisites.
- Every external source and binary input is pinned to an immutable version and expected digest.
- Every wait is bounded and reports a specific timeout; no correctness assertion depends on a fixed sleep.

---

### Task 1: Establish the Python quality boundary

**Files:**
- Create: `yabridge-test-infra/test-harness/tests/conftest.py`
- Create: `yabridge-test-infra/test-harness/tests/test_collection_guard.py`
- Create: `yabridge-test-infra/test-harness/tests/test_schemas.py`
- Modify: `yabridge-test-infra/test-harness/pyproject.toml`
- Modify: `yabridge-test-infra/test-harness/src/yabridge_test/cli.py`
- Modify: `yabridge-test-infra/test-harness/src/yabridge_test/environment.py`
- Modify: `yabridge-test-infra/test-harness/src/yabridge_test/schemas.py`
- Modify: `yabridge-test-infra/test-harness/src/yabridge_test/tests/plugin_load.py`
- Modify: `yabridge-test-infra/.gitignore`

**Interfaces:**
- Produces: a top-level `tests/` suite collected only from `test-harness/tests`.
- Produces: strict pytest configuration that raises `pytest.UsageError("no harness tests collected")` on zero tests.
- Produces: timezone-aware UTC defaults for report timestamps.

- [ ] **Step 1: Write the collection guard and its failing unit test**

```python
# tests/conftest.py
import pytest

def pytest_collection_finish(session: pytest.Session) -> None:
    if not session.items:
        raise pytest.UsageError("no harness tests collected")
```

```python
# tests/test_collection_guard.py
from types import SimpleNamespace
import pytest
from conftest import pytest_collection_finish

def test_zero_collection_is_an_explicit_failure() -> None:
    with pytest.raises(pytest.UsageError, match="no harness tests collected"):
        pytest_collection_finish(SimpleNamespace(items=[]))
```

- [ ] **Step 2: Run the new boundary and witness the current configuration failure**

Run:

```bash
cd yabridge-test-infra/test-harness
python -m pytest --strict-config -q
```

Expected: fail because `pytest-asyncio` is unavailable or because the configured test path did not previously exist.

- [ ] **Step 3: Make test dependencies and static configuration deterministic**

In `pyproject.toml`:

```toml
[project.optional-dependencies]
dev = [
    "pytest>=7.0.0",
    "pytest-asyncio>=0.21.0",
    "mypy>=1.5.0",
    "ruff>=0.1.0",
    "types-psutil>=5.9.0",
]

[tool.pytest.ini_options]
testpaths = ["tests"]
addopts = ["--strict-config", "--strict-markers", "-ra"]
filterwarnings = ["error"]
```

Replace `datetime.utcnow` with `datetime.now(timezone.utc)`, make `run_command()` accept `str | None` defaults, and remove Ruff findings without suppressing them. Add `.ruff_cache/` to `.gitignore`.

- [ ] **Step 4: Verify the full quality boundary**

Run:

```bash
cd yabridge-test-infra/test-harness
python -m pip install -e ".[dev]"
python -m pytest -q
python -m mypy src/
python -m ruff check src/ tests/
```

Expected: all pass with at least two collected tests.

- [ ] **Step 5: Commit**

```bash
git add .gitignore test-harness
git commit -m "test: establish strict harness quality gates"
```

---

### Task 2: Centralize result and exit semantics

**Files:**
- Create: `yabridge-test-infra/test-harness/tests/test_cli_exit_status.py`
- Modify: `yabridge-test-infra/test-harness/src/yabridge_test/schemas.py`
- Modify: `yabridge-test-infra/test-harness/src/yabridge_test/cli.py`

**Interfaces:**
- Produces: `ResultSummary.from_results(results: Sequence[SingleTestResult]) -> ResultSummary`.
- Produces: `ResultSummary.unsuccessful: bool`, true for empty results or any `FAIL`/`ERROR`.
- Produces: `exit_for_results(results) -> NoReturn | None`, shared by `validate`, `plugin`, and `suite`.

- [ ] **Step 1: Write failing summary and Click exit tests**

```python
@pytest.mark.parametrize("status", [TestResult.FAIL, TestResult.ERROR])
def test_unsuccessful_status_exits_nonzero(runner, monkeypatch, status):
    monkeypatch.setattr(MouseCoordinateTest, "run_all", lambda self: [
        SingleTestResult(name="probe", result=status)
    ])
    assert runner.invoke(main, ["validate"]).exit_code == 1

def test_empty_execution_exits_nonzero(runner, monkeypatch):
    monkeypatch.setattr(MouseCoordinateTest, "run_all", lambda self: [])
    assert runner.invoke(main, ["validate"]).exit_code == 1
```

Also test `plugin`, `suite`, and failed `suite --submit`.

- [ ] **Step 2: Witness `ERROR` and empty runs currently exit zero**

Run:

```bash
python -m pytest tests/test_cli_exit_status.py -q
```

Expected: failures for `ERROR`, empty results, and failed submission.

- [ ] **Step 3: Implement one aggregation rule**

```python
class ResultSummary(BaseModel):
    passed: int
    failed: int
    errors: int
    skipped: int
    total: int

    @classmethod
    def from_results(cls, results: Sequence[SingleTestResult]) -> "ResultSummary":
        counts = Counter(result.result for result in results)
        return cls(
            passed=counts[TestResult.PASS],
            failed=counts[TestResult.FAIL],
            errors=counts[TestResult.ERROR],
            skipped=counts[TestResult.SKIP],
            total=len(results),
        )

    @property
    def unsuccessful(self) -> bool:
        return self.total == 0 or self.failed > 0 or self.errors > 0
```

Route every command through this summary. A failed submission must set a nonzero exit independent of test counts.

- [ ] **Step 4: Verify focused and full tests**

Run:

```bash
python -m pytest tests/test_cli_exit_status.py -q
python -m pytest -q
python -m mypy src/
```

- [ ] **Step 5: Commit**

```bash
git add test-harness
git commit -m "fix: treat harness errors as unsuccessful runs"
```

---

### Task 3: Record staging identity and distinguish Wayland from XWayland

**Files:**
- Create: `yabridge-test-infra/test-harness/src/yabridge_test/provenance.py`
- Create: `yabridge-test-infra/test-harness/tests/test_provenance.py`
- Create: `yabridge-test-infra/test-harness/tests/test_display_server.py`
- Modify: `yabridge-test-infra/test-harness/src/yabridge_test/environment.py`
- Modify: `yabridge-test-infra/test-harness/src/yabridge_test/schemas.py`
- Modify: `yabridge-test-infra/test-harness/src/yabridge_test/cli.py`

**Interfaces:**
- Produces: `StagingIdentity.load(root: Path) -> StagingIdentity | None`.
- Produces: `detect_display_environment(environ: Mapping[str, str]) -> tuple[DisplayServer, bool]`.
- Adds: `Environment.xwayland_available: bool`.
- Preserves: `Environment.display_server` as the native session (`WAYLAND` for a Wayland session even when `DISPLAY` is set).

- [ ] **Step 1: Write table-driven display tests**

```python
@pytest.mark.parametrize(
    ("env", "session", "xwayland"),
    [
        ({"XDG_SESSION_TYPE": "wayland", "WAYLAND_DISPLAY": "wayland-0", "DISPLAY": ":0"},
         DisplayServer.WAYLAND, True),
        ({"XDG_SESSION_TYPE": "wayland", "WAYLAND_DISPLAY": "wayland-0"},
         DisplayServer.WAYLAND, False),
        ({"XDG_SESSION_TYPE": "x11", "DISPLAY": ":0"}, DisplayServer.X11, False),
    ],
)
def test_display_session_is_separate_from_xwayland(env, session, xwayland):
    assert detect_display_environment(env) == (session, xwayland)
```

- [ ] **Step 2: Write non-evaluating provenance tests**

Fixtures contain `build/component-state.env` and `run-state/run-manifest.json`. Assert exact 40-hex commit/ref are loaded, schema or state mismatches fail closed, and `YABRIDGE_COMMIT=$(touch owned)` never executes or parses.

- [ ] **Step 3: Witness current detectors conflate Wayland/XWayland and omit staging commit**

Run:

```bash
python -m pytest tests/test_display_server.py tests/test_provenance.py -q
```

- [ ] **Step 4: Implement strict provenance parsing and environment integration**

State grammar:

```python
STATE_LINE = re.compile(r"^(?P<key>[A-Z0-9_]+)=(?P<value>[A-Za-z0-9._:/+@-]+)$")
COMMIT = re.compile(r"^[0-9a-fA-F]{40}$")
```

Prefer verified staging state rooted at `YABRIDGE_TEST_ROOT`; use `BUILD_INFO` only for the VM fallback. Pass `plugin_path` to `collect_environment()` from `plugin` and `suite` so Wine-prefix detection is no longer dead.

- [ ] **Step 5: Verify**

Run:

```bash
python -m pytest tests/test_display_server.py tests/test_provenance.py -q
python -m mypy src/
python -m ruff check src/ tests/
```

- [ ] **Step 6: Commit**

```bash
git add test-harness
git commit -m "fix: record exact staging and display identities"
```

---

### Task 4: Resolve managed bridges instead of guessing paths

**Files:**
- Create: `yabridge-test-infra/test-harness/src/yabridge_test/bridge_discovery.py`
- Create: `yabridge-test-infra/test-harness/tests/test_bridge_discovery.py`
- Modify: `yabridge-test-infra/test-harness/src/yabridge_test/tests/plugin_load.py`

**Interfaces:**
- Produces: `BridgeRecord(windows_path: Path, bridge_path: Path, plugin_type: PluginType)`.
- Produces: `discover_bridge(plugin_path, plugin_type, environ, staging_identity) -> BridgeRecord | None`.
- Produces: `parse_yabridgectl_status(text: str) -> list[BridgeRecord]`.

- [ ] **Step 1: Create realistic bridge fixtures and failing tests**

Cover:

```text
.vst/yabridge/Good.dll -> <clone>/Good.dll
.vst/yabridge/Good.so
.clap/yabridge/Good.clap-win -> <clone>/Good.clap
.clap/yabridge/Good.clap
.vst3/yabridge/Good.vst3/Contents/x86_64-win/Good.vst3 -> <clone>/Good.vst3
.vst3/yabridge/Good.vst3/Contents/x86_64-linux/Good.so
```

Assert canonical target equality, escaping/broken metadata rejection, exact status matching, and unrelated status errors do not taint the selected plugin.

- [ ] **Step 2: Witness the current `.with_suffix(".so")` assumptions fail**

Run:

```bash
python -m pytest tests/test_bridge_discovery.py -q
```

- [ ] **Step 3: Implement managed-root discovery**

Discovery order:

1. `VST_PATH`, `VST3_PATH`, or `CLAP_PATH`.
2. Verified `bridge_roots` from `run-state/run-manifest.json`.
3. Isolated yabridgectl config/status fixtures.

Every metadata symlink must resolve exactly to the requested canonical Windows plugin. Never match by basename substring.

- [ ] **Step 4: Route plugin checks and Carla scanning through `BridgeRecord`**

`check_yabridge_bridge()`, `check_yabridgectl_status()`, and `test_plugin_scan_carla()` consume one resolved record. `test_wine_prefix_access()` uses `detect_wine_prefix(self.plugin_path)`.

- [ ] **Step 5: Verify and commit**

```bash
python -m pytest tests/test_bridge_discovery.py -q
python -m pytest -q
python -m mypy src/
git add test-harness
git commit -m "fix: resolve yabridge-managed plugin bridges"
```

---

### Task 5: Define the coordinate probe protocol and verdict engine

**Files:**
- Create: `yabridge-test-infra/test-harness/src/yabridge_test/probe/__init__.py`
- Create: `yabridge-test-infra/test-harness/src/yabridge_test/probe/protocol.py`
- Create: `yabridge-test-infra/test-harness/src/yabridge_test/probe/scenarios.py`
- Create: `yabridge-test-infra/test-harness/src/yabridge_test/probe/evaluator.py`
- Create: `yabridge-test-infra/test-harness/tests/test_probe_protocol.py`
- Create: `yabridge-test-infra/test-harness/tests/test_probe_evaluator.py`
- Modify: `yabridge-test-infra/test-harness/src/yabridge_test/schemas.py`
- Modify: `yabridge-test-infra/test-harness/src/yabridge_test/tests/mouse_coords.py`

**Interfaces:**
- Produces: versioned JSONL `decode_message(line: bytes) -> ProbeMessage`.
- Produces: `evaluate_sample(sample: ProbeSample, tolerance: int) -> ProbeVerdict`.
- Adds: `SingleTestResult.measurements: dict[str, Any] | None`.
- Retires: global-pointer methods as verdicts; `MouseCoordinateTest.run_all()` returns one prerequisite `SKIP`/`PASS` and never claims issue #409 status.

- [ ] **Step 1: Write protocol rejection tests**

Test valid v1 messages, unknown fields, malformed/truncated JSON, duplicate sequence numbers, lines over 64 KiB, wrong token, and unsupported protocol versions.

- [ ] **Step 2: Write a golden issue-409 trace before implementation**

```python
def test_local_as_global_trace_is_classified() -> None:
    sample = ProbeSample(
        x11_origin=(317, 211),
        warp=(517, 361),
        win_client=(517, 361),
        win_origin=(317, 211),
        cursor=(517, 361),
    )
    verdict = evaluate_sample(sample, tolerance=2)
    assert verdict.result is TestResult.FAIL
    assert verdict.classification == "issue_409_local_as_global"
```

- [ ] **Step 3: Witness the detector is absent and the legacy branch cannot satisfy this trace**

Run:

```bash
python -m pytest tests/test_probe_protocol.py tests/test_probe_evaluator.py -q
```

- [ ] **Step 4: Implement protocol and four assertions**

Evaluate origin agreement, client coordinates, cursor position, and button coordinates. Preserve raw samples in `measurements`; never widen tolerance to turn missing events into passes.

- [ ] **Step 5: Demote the legacy pointer round-trip**

Rename it to `PointerBackendSanity`; missing XTEST is `SKIP`, available XTEST is only `PASS`. Remove the unreachable offset verdict and update exports.

- [ ] **Step 6: Verify and commit**

```bash
python -m pytest tests/test_probe_protocol.py tests/test_probe_evaluator.py -q
python -m pytest -q
git add test-harness
git commit -m "test: define bridged coordinate probe verdicts"
```

---

### Task 6: Build the pinned Windows CLAP probe and pure-Wine baseline

**Files:**
- Create: `yabridge-test-infra/probe/README.md`
- Create: `yabridge-test-infra/probe/meson.build`
- Create: `yabridge-test-infra/probe/subprojects/clap.wrap`
- Create: `yabridge-test-infra/probe/cross/mingw-w64-x86_64.ini`
- Create: `yabridge-test-infra/probe/include/probe/protocol.h`
- Create: `yabridge-test-infra/probe/src/common/jsonl.c`
- Create: `yabridge-test-infra/probe/src/common/jsonl.h`
- Create: `yabridge-test-infra/probe/src/plugin/entry.c`
- Create: `yabridge-test-infra/probe/src/plugin/gui.c`
- Create: `yabridge-test-infra/probe/src/plugin/window.c`
- Create: `yabridge-test-infra/probe/src/plugin/report.c`
- Create: `yabridge-test-infra/probe/src/selftest/win_selftest.c`
- Create: `yabridge-test-infra/test-harness/tests/test_probe_artifact.py`
- Create: `yabridge-test-infra/test-harness/tests/test_probe_wine_baseline.py`
- Modify: `yabridge-test-infra/.gitignore`

**Interfaces:**
- Produces: reproducible `coordprobe.clap-win` and `coordprobe-selftest.exe`.
- Consumes: `YABRIDGE_PROBE_ENDPOINT` and `YABRIDGE_PROBE_TOKEN`.
- Emits: `hello`, `attached`, `mouse`, `mark`, `origin`, `size`, `error`, and `bye` JSONL events.

- [ ] **Step 1: Pin CLAP 1.1.9 to yabridge's exact upstream commit**

Use the same immutable revision as yabridge:

```ini
[wrap-git]
url = https://github.com/free-audio/clap.git
# Upstream tag 1.1.9
revision = 094bb76c85366a13cc6c49292226d8608d6ae50c
depth = 1

[provide]
clap = clap_dep
```

Record the URL, tag, commit, and MIT license in `probe/README.md`; CI must assert the checked-out subproject HEAD equals this commit.

- [ ] **Step 2: Write artifact-shape and reproducibility tests**

Pure Python reads the PE header and asserts machine `0x8664`. Two clean builds must produce identical SHA-256 values using `--no-insert-timestamp` and `-ffile-prefix-map`.

- [ ] **Step 3: Build a minimal CLAP plugin and witness missing GUI/report behavior**

The plugin is no-op audio plus `CLAP_EXT_GUI`. `set_parent()` creates a `WS_CHILD | WS_VISIBLE` child at `(0, 0)`. Extract signed mouse coordinates with `GET_X_LPARAM`/`GET_Y_LPARAM`.

- [ ] **Step 4: Implement the out-of-band report channel**

The socket thread posts `WM_APP_MARK` and `WM_APP_QUERY_ORIGIN`; only the window procedure emits replies. Reject missing endpoint/token, line overflow, and partial writes with explicit `error` events.

- [ ] **Step 5: Add the pure-Wine baseline**

Under temporary Xvfb and Wine prefix, `coordprobe-selftest.exe` loads the plugin and supplies its own top-level HWND. Assert reported client coordinates match X11 truth before involving yabridge. Skip only when Wine, MinGW, or Xvfb is unavailable and include the missing prerequisite in the skip reason.

- [ ] **Step 6: Verify and commit**

```bash
meson setup probe/build-native probe
meson setup --cross-file probe/cross/mingw-w64-x86_64.ini probe/build-win probe
meson compile -C probe/build-win
cd test-harness
python -m pytest tests/test_probe_artifact.py tests/test_probe_wine_baseline.py -q
git add probe test-harness/tests .gitignore
git commit -m "feat: add deterministic Wine coordinate probe"
```

---

### Task 7: Build the Linux CLAP host and transport

**Files:**
- Create: `yabridge-test-infra/probe/src/host/main.c`
- Create: `yabridge-test-infra/probe/src/host/clap_host.c`
- Create: `yabridge-test-infra/probe/src/host/hierarchy.c`
- Create: `yabridge-test-infra/probe/src/host/xprobe.c`
- Create: `yabridge-test-infra/test-harness/src/yabridge_test/probe/transport.py`
- Create: `yabridge-test-infra/test-harness/tests/test_probe_host.py`
- Create: `yabridge-test-infra/test-harness/tests/test_probe_transport.py`
- Modify: `yabridge-test-infra/probe/meson.build`

**Interfaces:**
- Produces: `clap-probe-host` with JSONL stdin/stdout control.
- Produces: `PluginListener` with token validation and bounded 64 KiB reads.
- Produces: `HostProcess` with process-group teardown and per-command deadlines.

- [ ] **Step 1: Write pure transport tests**

Use socket pairs and fake child processes to test token mismatch, timeout, truncated line, oversized line, process death, sequence ordering, and teardown.

- [ ] **Step 2: Implement host `--no-plugin` mode**

Commands: `open`, `place`, `warp`, `button`, `geometry`, `resize`, `synthetic_configure`, `close`. Events: `ready`, `gui_opened`, `warped`, `geometry`, `x11`, `clap`, `error`.

- [ ] **Step 3: Test X11 hierarchies without Wine**

Under Xvfb, compare host-reported geometry to an independent Xlib query for flat, nested-relative, and nested-synthetic-absolute modes. Wait for `MapNotify`/`ConfigureNotify`; do not sleep.

- [ ] **Step 4: Add CLAP loading**

Use `dlopen`, `clap_entry`, factory lookup, plugin init/activate, GUI create/set_parent/show, and bounded teardown. Host extensions remain optional.

- [ ] **Step 5: Verify and commit**

```bash
meson compile -C probe/build-native
cd test-harness
python -m pytest tests/test_probe_host.py tests/test_probe_transport.py -q
python -m mypy src/
git add probe test-harness
git commit -m "feat: host bridged coordinate probe scenarios"
```

---

### Task 8: Run the bridged scenario matrix and expose it through the CLI

**Files:**
- Create: `yabridge-test-infra/test-harness/src/yabridge_test/probe/discovery.py`
- Create: `yabridge-test-infra/test-harness/src/yabridge_test/probe/fixture.py`
- Create: `yabridge-test-infra/test-harness/src/yabridge_test/probe/xserver.py`
- Create: `yabridge-test-infra/test-harness/src/yabridge_test/probe/runner.py`
- Create: `yabridge-test-infra/test-harness/src/yabridge_test/tests/wine_child_window.py`
- Create: `yabridge-test-infra/test-harness/tests/test_probe_discovery.py`
- Create: `yabridge-test-infra/test-harness/tests/test_probe_runner.py`
- Create: `yabridge-test-infra/test-harness/tests/test_probe_cli.py`
- Modify: `yabridge-test-infra/test-harness/src/yabridge_test/tests/__init__.py`
- Modify: `yabridge-test-infra/test-harness/src/yabridge_test/cli.py`

**Interfaces:**
- Produces: `WineChildWindowTest.run_all() -> list[SingleTestResult]`.
- Produces: `yabridge-test probe` command.
- Makes: `validate` and `suite` use measured bridged scenarios.

- [ ] **Step 1: Write discovery and fixture tests**

Prefer a full `libyabridge-clap.so`, support the chainloader explicitly, require adjacent `yabridge-host.exe`, build `probe.clap` plus `probe.clap-win`, and record which mode/version/hash ran. No `yabridgectl` or production plugin directory is used.

- [ ] **Step 2: Write runner tests over golden event traces**

Cover `origin`, `offset`, `move_after_open`, `pointer_inside_on_open`, `nested`, `nested_synthetic_abs`, `resize`, and `wm_managed`. Missing events and timeouts are `ERROR`, not `SKIP` or `PASS`.

- [ ] **Step 3: Implement X server lifecycle**

Allocate a temporary display, poll `xdpyinfo` readiness, optionally start Openbox, save/restore pointer on interactive runs, and terminate process groups on `EXIT`, `INT`, and `TERM`.

- [ ] **Step 4: Implement the bridged fixture and scenario runner**

Use temporary directories and the current Wine prefix. The plugin reports over loopback TCP with a random token. Compare bridged samples to the pure-Wine baseline and classify classic issue #409 separately.

- [ ] **Step 5: Add CLI behavior**

```text
yabridge-test probe [--scenario NAME] [--headless/--no-headless]
                    [--yabridge-lib PATH] [--wine-prefix PATH]
                    [--samples N] [--tolerance PX] [--json]
```

`validate` calls the probe plus pointer prerequisite. `suite` includes probe results. Missing optional desktop prerequisites are explicit `SKIP`; a started probe that cannot produce measurements is `ERROR`.

- [ ] **Step 6: Verify and commit**

```bash
python -m pytest tests/test_probe_discovery.py tests/test_probe_runner.py tests/test_probe_cli.py -q
python -m pytest -q
python -m mypy src/
python -m ruff check src/ tests/
git add test-harness
git commit -m "feat: measure Wine child-window coordinates through yabridge"
```

---

### Task 9: Preserve probe measurements in the service and enforce harness CI

**Files:**
- Create: `yabridge-test-infra/web/tests/test_probe_submission.py`
- Create: `yabridge-test-infra/.github/workflows/test-harness.yml`
- Create: `yabridge-test-infra/.github/workflows/probe.yml`
- Modify: `yabridge-test-infra/web/app/schemas.py`
- Modify: `yabridge-test-infra/.github/workflows/build-images.yml`

**Interfaces:**
- Preserves: `SingleTestResult.measurements` through API validation/storage.
- Enforces: harness pytest/mypy/Ruff on `test-harness/**` changes.
- Enforces: native/MinGW probe builds on `probe/**` changes.

- [ ] **Step 1: Write a failing API round-trip test**

Submit a result containing:

```json
{"name":"wine_child_window_offset","result":"fail",
 "measurements":{"classification":"issue_409_local_as_global","delta":[317,211]}}
```

Assert `measurements` survives validation and result retrieval.

- [ ] **Step 2: Add the additive web schema field**

```python
measurements: dict[str, Any] | None = None
```

Do not change authentication, publication, or lifecycle behavior in this phase.

- [ ] **Step 3: Split CI path coverage**

`test-harness.yml` installs `.[dev]` and runs pytest, mypy, and Ruff. `probe.yml` installs Meson, Ninja, MinGW, X11/XTest headers, builds both artifacts, runs artifact and native-host tests, and uploads SHA-256 manifests. Remove the unreachable harness/web jobs from the Packer-only workflow.

- [ ] **Step 4: Verify and commit**

```bash
cd test-harness && python -m pytest -q && python -m mypy src/ && python -m ruff check src/ tests/
cd ../web && python -m pytest tests/test_probe_submission.py -q
git add .github web test-harness
git commit -m "ci: enforce harness and probe correctness"
```

---

### Task 10: Document, review, and record the submodule

**Files:**
- Create: `yabridge-test-infra/docs/coord-probe.md`
- Modify: `yabridge-test-infra/docs/test-protocol.md`
- Modify: `yabridge-test-infra/docs/architecture.md`
- Modify: `yabridge-test-infra/test-harness/README.md`
- Modify: `README.md`
- Modify: `yabridge-test-infra` gitlink
- Modify: `tests/setup_harness.bats` only if the root install command changes

**Interfaces:**
- Documents: protocol v1, scenario semantics, skip/error policy, interactive pointer warning, exact build prerequisites, and failure interpretation.
- Produces: committed submodule HEAD followed by a parent commit recording that HEAD.

- [ ] **Step 1: Document operational and residual constraints**

Include CLAP 1.1.9 pin/hash, MinGW requirement, Xvfb/Openbox requirements, loopback-only endpoint/token, XWayland result separation, multi-monitor skip policy, bounded waits, and the distinction between pure-Wine baseline and bridged verdict.

- [ ] **Step 2: Run complete submodule verification**

```bash
cd yabridge-test-infra/test-harness
python -m pytest -q
python -m mypy src/
python -m ruff check src/ tests/
cd ../web
python -m pytest -q
cd ../probe
meson setup --wipe build-native
meson compile -C build-native
meson setup --wipe --cross-file cross/mingw-w64-x86_64.ini build-win
meson compile -C build-win
```

- [ ] **Step 3: Request a full submodule review**

Review from `9eb2e8a` to submodule HEAD for result false-greens, provenance spoofing, bridge misidentification, protocol injection, unbounded waits, process leaks, wrong coordinate transforms, and CI skips.

- [ ] **Step 4: Commit submodule documentation**

```bash
cd yabridge-test-infra
git add docs test-harness/README.md
git commit -m "docs: explain deterministic bridged coordinate testing"
```

- [ ] **Step 5: Record the submodule pointer in the parent**

```bash
cd ..
git add yabridge-test-infra
git commit -m "feat: record harness correctness remediation"
```

- [ ] **Step 6: Verify parent integration**

```bash
bats tests/setup_harness.bats
bash -n setup.sh daw-env.sh lib/*.sh
shellcheck -e SC1091 setup.sh daw-env.sh lib/*.sh tests/*.bash
git diff --check
git status --short --branch
```

Expected: all checks pass and both repositories are clean.
