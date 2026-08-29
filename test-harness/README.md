# Yabridge Test Harness

CLI for standardized yabridge testing with Wine 10+, including the deterministic
bridged coordinate probe.

Full probe documentation: [../docs/coord-probe.md](../docs/coord-probe.md)

## Installation

```bash
python -m venv .venv
source .venv/bin/activate
pip install -e .
```

Development dependencies:

```bash
pip install -e ".[dev]"
```

## Build probe artifacts (required for live runs)

```bash
cd ../probe
meson setup build-native .
meson compile -C build-native
meson setup --cross-file cross/mingw-w64-x86_64.ini build-win .
meson compile -C build-win
```

## Usage

### Environment info

```bash
yabridge-test info
yabridge-test info --json
```

Captures distro, desktop, native display session, XWayland availability, Wine,
yabridge, DPI, and monitors.

### Coordinate probe

```bash
# Full matrix (headless Xvfb, default)
yabridge-test probe

# Machine-readable output
yabridge-test probe --json

# One scenario
yabridge-test probe --scenario offset --samples 3 --tolerance 4 --json
```

Flags:

| Flag | Purpose |
|------|---------|
| `--scenario` | One of `origin`, `offset`, `move_after_open`, `pointer_inside_on_open`, `nested`, `nested_synthetic_abs`, `resize`, `wm_managed` |
| `--headless` / `--no-headless` | Own Xvfb (default) vs use existing `DISPLAY` |
| `--allow-pointer-warp` | Required with `--no-headless` to move the session pointer |
| `--yabridge-lib` | Explicit `libyabridge-clap.so` or chainloader (invalid → ERROR) |
| `--wine-prefix` | Reuse a prefix; omitted prefixes use `yabridge-probe-prefix-*` temp dirs |
| `--samples` | Repeated measurements per scenario (default `1`) |
| `--tolerance` | Pixel tolerance (default `2`) |
| `--json` | Emit structured JSON on stdout |

Environment variables: `YABRIDGE_PROBE_LIB`, `YABRIDGE_LIB`, `YABRIDGE_TEST_ROOT`.

### Validation and suite

```bash
# Pointer prerequisite + full probe matrix
yabridge-test validate

# Environment + probe (+ optional plugin)
yabridge-test suite
yabridge-test suite --plugin /path/to/plugin.vst3 --submit
```

`suite` prints native session type and XWayland availability separately.

### Plugin and submission

```bash
yabridge-test plugin /path/to/plugin.vst3
yabridge-test submit --file results.json
yabridge-test submit --session
yabridge-test probe --submit
```

Submit always POSTs `/api/v1/drafts` and prints an edit URL. Use `--dry-run`
to print the sanitized payload without sending it.

## Result semantics

| Result | CLI impact |
|--------|------------|
| PASS | success |
| FAIL | exit 1 |
| ERROR | exit 1 |
| SKIP | success (missing optional prerequisite) |

Probe measurements include raw host/plugin events, independent X11 geometry, XTest
observations, per-field assertions, baseline state, and optional
`classification: issue_409_local_as_global`.

## Test result shape

```json
{
  "name": "probe_offset",
  "result": "fail",
  "details": "issue_409_local_as_global",
  "measurements": {
    "x11_origin": [317, 211],
    "warp": [358, 240],
    "expected_client": [41, 29],
    "motion_client": [358, 240],
    "classification": "issue_409_local_as_global",
    "baseline": {"result": "pass", "details": "pure-Wine baseline passed"},
    "assertions": [
      {
        "name": "motion_client",
        "result": "fail",
        "expected": [41, 29],
        "actual": [358, 240],
        "delta": [317, 211]
      }
    ]
  }
}
```

## Development

### Test markers

```bash
# Default CI selection (no probe artifacts required)
python -m pytest -q -m "not native_probe and not wine_probe and not live_probe"

# After building probe/
python -m pytest -q -m native_probe

# Wine baseline integration
python -m pytest -q -m wine_probe

# Live yabridge opt-in
YABRIDGE_LIVE_LIB=/path/to/libyabridge-clap.so python -m pytest -q -m live_probe
```

| Marker | CI workflow |
|--------|---------------|
| pure (default) | `.github/workflows/test-harness.yml` |
| `native_probe` | `.github/workflows/probe.yml` |
| `wine_probe` | local/manual |
| `live_probe` | local/manual (`YABRIDGE_LIVE_LIB`) |

### Quality checks

```bash
python -m pytest -q
python -m mypy src/
python -m ruff check src/ tests/
```

Documentation regression tests live in `tests/test_docs.py`.

## Troubleshooting quick reference

| Issue | Check |
|-------|-------|
| All probe SKIP | Built `probe/build-native` and `probe/build-win`? Wine/Xvfb installed? |
| ERROR on explicit library | Path must be `libyabridge-clap.so` or chainloader with adjacent host |
| Pointer opt-in error | Add `--allow-pointer-warp` with `--no-headless` |
| Cold Wine/timeouts | Warm prefix or retry; baseline deadline is 30 s |
| XTEST absent in `validate`/`suite` | `pointer_backend_sanity` SKIP; install Xvfb/XTEST or use X11 |
| Probe ERROR after startup (XTest/libXtst) | Live probe failed mid-run; not a prerequisite SKIP |
| `wm_managed` SKIP | Install `openbox` and `xprop`, or ignore optional scenario |
| MinGW build failure | Install `gcc-mingw-w64-x86-64` |
| Baseline ERROR | Fix pure-Wine coordinates before trusting bridged FAIL/PASS |

See [../docs/coord-probe.md](../docs/coord-probe.md) for protocol, scenario, and
classification details.
