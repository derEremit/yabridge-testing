# Coordinate probe

Deterministic bridged Wine child-window coordinate testing for yabridge. The probe
loads a pinned CLAP fixture through a selected `libyabridge-clap.so`, injects XTest
input on an owned or explicitly approved X display, and compares what the Wine child
window reports against independent host-side geometry.

See also: [Test protocol](test-protocol.md) and
the [test harness README](../test-harness/README.md).

## What it measures

The verdict comes from a Wine child window reached through yabridge, not from a global
pointer round trip. `pointer_backend_sanity` may only report PASS or SKIP when the
XTEST extension is available; it never claims issue #409 coordinate verdicts.

Each scenario produces raw measurements with independent fields:

- `independent_x11` from the native host's direct Xlib query
- `xtest` from host-side observation of the injected press/release
- plugin `mouse` events with `client_x`/`client_y`, `screen_x`/`screen_y`,
  `cursor_x`/`cursor_y`, and `virtual_x`/`virtual_y`
- per-assertion expected/actual/delta tuples inside `measurements.assertions`

## Build prerequisites

Build both probe artifacts before running live scenarios:

```bash
cd probe
meson setup build-native .
meson compile -C build-native
meson setup --cross-file cross/mingw-w64-x86_64.ini build-win .
meson compile -C build-win
```

Required outputs:

| Artifact | Path |
|----------|------|
| Native CLAP host | `probe/build-native/clap-probe-host` |
| Windows probe plugin | `probe/build-win/coordprobe.clap-win` |
| Pure-Wine baseline | `probe/build-win/coordprobe-selftest.exe` |

Additional runtime prerequisites for live runs:

- `wine` and `wineserver`
- `Xvfb` and `xdpyinfo` for headless mode (default)
- `libX11.so.6` and `libXtst.so.6` for XTest input and pointer evidence
- MinGW-w64 (`x86_64-w64-mingw32-gcc`) and Meson to build the Windows artifacts
- `openbox` and `xprop` only for the optional `wm_managed` scenario

### CLAP pin (immutable)

The Windows plugin is built against CLAP **1.1.9**, pinned to upstream commit
`094bb76c85366a13cc6c49292226d8608d6ae50c` in `probe/subprojects/clap.wrap`.
Changing or floating that revision fails CI without rebuilding.

## Protocol v1

Host and plugin communicate over newline-delimited JSON on loopback TCP. Every line
is a JSON object using the `v` / `seq` / `type` / `token` envelope with these
top-level fields:

| Field | Meaning |
|-------|---------|
| `v` | Protocol version; must be `1` |
| `seq` | Contiguous sequence number starting at `0`, incrementing exactly by `1`; gaps, duplicates, and out-of-order values reject the session (`duplicate sequence number`, `out-of-order sequence number`) |
| `type` | Message type; see supported values below |
| `token` | Shared secret authenticating the session |

Additional fields depend on `type`. Supported `type` values:

`attached`, `button`, `bye`, `clap`, `close`, `error`, `geometry`, `gui_opened`,
`hello`, `mark`, `mouse`, `open`, `origin`, `place`, `ready`, `resize`, `size`,
`synthetic_configure`, `warp`, `warped`, `x11`

Lines are UTF-8, at most 64 KiB including the
newline. The listener binds `127.0.0.1` on an ephemeral port; both
`YABRIDGE_PROBE_ENDPOINT` and `YABRIDGE_PROBE_TOKEN` must match that session.

`mark` labels delimit event buckets. Marks do **not** order hardware input delivery.
The runner therefore uses bounded wall-clock deadlines and short quiescence slices
(`0.05` s by default) to decide when plugin-side evidence has settled.

## yabridge discovery

Discovery prefers, in order:

1. `--yabridge-lib` / `YABRIDGE_PROBE_LIB`
2. `YABRIDGE_LIB`
3. verified staging at `YABRIDGE_TEST_ROOT`
4. `~/.local/share/yabridge/libyabridge-clap.so`

Supported library names:

- `libyabridge-clap.so` (full mode)
- `libyabridge-chainloader-clap.so` (chainloader mode)

Chainloader mode additionally requires
`~/.local/share/yabridge/libyabridge-clap.so` and the chainloader host directory
on `PATH`. Each run records `mode`, `version`, and `sha256` of the selected library.

The temporary fixture never uses production plugin directories or `yabridgectl`.

## CLI

```bash
yabridge-test probe [--scenario NAME] [--headless/--no-headless]
                    [--allow-pointer-warp] [--yabridge-lib PATH]
                    [--wine-prefix PATH] [--samples N] [--tolerance PX] [--json]
```

| Flag | Default | Notes |
|------|---------|-------|
| `--scenario` | all eight | One of the scenario names below |
| `--headless` | on | Own an Xvfb display (`1280x800x24`) |
| `--no-headless` | | Use existing `DISPLAY`; see pointer warning |
| `--allow-pointer-warp` | off | Required with `--no-headless` |
| `--yabridge-lib` | auto | Explicit invalid library → ERROR |
| `--wine-prefix` | temporary | Externally supplied prefix is never killed |
| `--samples` | `1` | Repeated measurements per scenario |
| `--tolerance` | `2` px | Coordinate comparison tolerance |
| `--json` | off | Machine-readable stdout |

Example:

```bash
yabridge-test probe --json
yabridge-test probe --scenario offset --samples 3 --tolerance 4 --json
```

`validate` and `suite` call `pointer_backend_sanity` plus the full probe matrix.

### XTEST and pointer backend

- `pointer_backend_sanity` (via `validate`/`suite`) **SKIPs** when `xdpyinfo` reports
  no XTEST extension.
- The live probe does **not** preflight XTEST during prerequisite discovery. After
  the X server starts, baseline and host-side XTest use `libXtst.so.6`; if XTEST is
  unavailable, started scenarios report **ERROR** (measurements incomplete), not SKIP.

### Interactive pointer warning

Headless mode owns an isolated Xvfb display and may warp the pointer freely. When
`--no-headless` is used on an existing session, pointer movement requires explicit
opt-in via `--allow-pointer-warp`. On exit the runner saves and restores the prior
pointer position.

## Wine prefix policy

When `--wine-prefix` is omitted, the runner creates
`yabridge-probe-prefix-*` under the system temp directory and runs
`wineserver -k` during cleanup. When a prefix is supplied externally, the runner
never kills that prefix's wineserver.

## Scenarios

| Scenario | Semantics |
|----------|-----------|
| `origin` | Window at `(0, 0)` |
| `offset` | Random non-origin placement |
| `move_after_open` | Reposition after GUI open |
| `pointer_inside_on_open` | Pre-open host warp inside future client area |
| `nested` | Nested Wine/CLAP hierarchy (`hierarchy=nested`) |
| `nested_synthetic_abs` | Synthetic absolute ConfigureNotify on CLAP parent |
| `resize` | Post-open resize to `401×233` |
| `wm_managed` | Openbox-managed reparenting (optional; skips if tools missing) |

Default per-scenario deadlines:

- scenario step deadline: `8.0` s
- pure-Wine baseline process: `30.0` s
- plugin TCP accept: `30.0` s

## Pure-Wine baseline vs bridged verdict

Before any bridged scenario, the runner executes two pure-Wine baseline cycles with
`coordprobe-selftest.exe` under the same prefix and display. The baseline checks
that Wine reports expected client and screen coordinates for XTest input without
yabridge involved.

| Baseline | Bridged outcome |
|----------|-----------------|
| PASS | Scenario measurements decide PASS/FAIL/ERROR |
| FAIL | Bridged scenarios become **ERROR** (`bridged verdict suppressed`) |

A pure-Wine PASS is a prerequisite, not the coordinate verdict under test.

## Result semantics

| Result | Meaning |
|--------|---------|
| **PASS** | All required evidence present and within tolerance |
| **FAIL** | Completed measurement with failed coordinate assertions or missing plugin input evidence after the input deadline |
| **ERROR** | Probe started but required measurements were not completed; invalid explicit library; baseline failure; protocol/timeout/transport failure; concurrent runner |
| **SKIP** | Missing optional prerequisite before the probe starts (artifacts, Xvfb, auto-discovered yabridge, Openbox/xprop for `wm_managed`) |

CLI exit code `1` when any result is FAIL or ERROR, or when submission fails.
All SKIP is success.

## issue_409 classification

When coordinate assertions fail, the evaluator may attach
`classification: issue_409_local_as_global` if deltas match the classic Wine 10
local-as-global signature (motion client error equals the X11 origin offset, or a
consistent triple offset across plugin origin, cursor, and plugin screen). This is a
measurement annotation on a completed FAIL, not a PASS override.

Interpretation tips:

- Compare `measurements.delta` to `measurements.x11_origin`
- Read `measurements.classification` only on FAIL results with full evidence
- A FAIL without that classification is still a real coordinate mismatch

## Residual limitations

- **Single display:** headless mode always uses one `1280×800` Xvfb screen. The
  probe does not model multi-monitor layouts; interactive `--no-headless` runs on
  multi-monitor sessions are unsupported and may mis-report offsets.
- **One runner per process:** a second concurrent `WineChildWindowTest` returns ERROR.
- **Openbox optional:** `wm_managed` SKIPs when `openbox` or `xprop` is absent.
- **Measured-run scope:** a nested FAIL on one root artifact build (for example
  `missing_plugin_input_evidence`) documents that run only; it is not a universal
  product claim about yabridge or Wine.

## Troubleshooting

| Symptom | Likely cause |
|---------|----------------|
| All scenarios SKIP (`missing prerequisite`) | Probe artifacts not built, or Wine/Xvfb missing |
| `explicit yabridge library is invalid` ERROR | Typo in `--yabridge-lib`; auto-missing library SKIPs instead |
| `existing display pointer warping requires explicit opt-in` | Used `--no-headless` without `--allow-pointer-warp` |
| `invalid authentication token` / duplicate seq | Stale process or protocol contamination on the loopback port |
| `plugin connection timed out` | Cold Wine prefix; retry or warm prefix with a manual `wineboot` |
| `pointer_backend_sanity` SKIP (`XTEST extension not available`) | `validate`/`suite` only; run under X11/Xvfb with XTEST |
| Probe ERROR after X server start (`libX11`/`libXtst` missing) | Live probe baseline or host XTest failed; not a SKIP |
| `missing prerequisite: Xvfb` | Headless run without Xvfb/xdpyinfo installed |
| `missing prerequisite: openbox, xprop` SKIP | Expected for `wm_managed` without a window manager |
| Meson MinGW failure | Install `gcc-mingw-w64-x86-64` / `g++-mingw-w64-x86-64` |
| `bridged verdict suppressed` ERROR | Fix pure-Wine baseline first; bridged numbers are not trusted |
| FAIL + `issue_409_local_as_global` | Classic window-position offset pattern; compare delta to origin |
| FAIL + `missing_plugin_input_evidence` | Completed run, but WM_MOUSEMOVE/LBUTTONDOWN/LBUTTONUP not all observed |

On the results site's completion page an automated (`probe`/`suite`/`plugin`)
report leads with these findings and pre-ticks the matching issue box:
`issue_409_local_as_global` → "Mouse coordinates offset",
`missing_plugin_input_evidence` → "Input never reaches the plugin". The
DAW-only sections (host, plugins, workarounds) are folded away for such runs.

## Development markers and CI

Pytest markers partition ownership:

| Marker | Requires | CI workflow |
|--------|----------|-------------|
| pure (default) | Python only | `test-harness.yml` |
| `native_probe` | Built native/MinGW artifacts | `probe.yml` after Meson build |
| `wine_probe` | Wine + Xvfb + built artifacts | local/manual |
| `live_probe` | `YABRIDGE_LIVE_LIB` opt-in | local/manual |

Pure tests must pass on a clean checkout without probe build outputs. The immutable
CLAP revision test runs from the full `test_probe_artifact.py` file in `probe.yml`.
