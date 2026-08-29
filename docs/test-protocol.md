# Test Protocol

Standard procedures for yabridge Wine 10 testing, including the deterministic
coordinate probe and manual DAW validation.

## Overview

Two layers coexist:

1. **Measured probe** — `yabridge-test probe` / `validate` / `suite` run eight
   scripted bridged scenarios with raw measurements and strict PASS/FAIL/ERROR/SKIP
   semantics. See [Coordinate probe](coord-probe.md).
2. **Manual DAW validation** — load real plugins in a host and exercise GUI
   interaction when automation cannot cover a case.

The probe replaces the legacy tautological global-pointer round trip. Global pointer
checks remain prerequisites only.

## Environment preparation

### System requirements

- Linux with Python 3.10+
- Wine 9.x or 10.x for live probe runs
- yabridge CLAP library (`libyabridge-clap.so` or chainloader) for live probe runs
- Built probe artifacts (`probe/build-native`, `probe/build-win`) for live runs
- Xvfb + xdpyinfo for default headless probe runs
- XTEST extension for pointer injection during live probe runs (see XTEST section below)

### Recommended test plugins (manual)

Free plugins for manual GUI testing:

1. **Vital** — popular synth, good GUI coverage
2. **TDR Nova** — moderate GUI complexity
3. **Dexed** — simple synth
4. **OB-Xd** — more complex GUI

### DAW hosts (manual)

- **Ardour** — common yabridge test host
- **Carla** — standalone host for quick checks
- **REAPER**
- **Bitwig**

## Automated coordinate probe

### Build once

```bash
cd probe
meson setup build-native .
meson compile -C build-native
meson setup --cross-file cross/mingw-w64-x86_64.ini build-win .
meson compile -C build-win
```

CLAP **1.1.9** is pinned to commit `094bb76c85366a13cc6c49292226d8608d6ae50c`.

### Run measured scenarios

```bash
cd test-harness
pip install -e ".[dev]"
yabridge-test probe --json
```

Useful variants:

```bash
# One scenario, repeated samples
yabridge-test probe --scenario offset --samples 3 --json

# Interactive display (requires explicit pointer approval)
yabridge-test probe --no-headless --allow-pointer-warp --json

# Pin library and reuse an existing Wine prefix
yabridge-test probe --yabridge-lib ~/.local/share/yabridge/libyabridge-clap.so \
  --wine-prefix ~/.wine --json
```

`validate` runs `pointer_backend_sanity` plus the full probe matrix.
`suite` adds environment capture and optional plugin tests.

### Interpreting probe results

| Result | Action |
|--------|--------|
| **PASS** | Coordinates matched within tolerance for all required fields |
| **FAIL** | Completed run with coordinate mismatch or missing plugin input after deadline; read `measurements` and optional `classification` |
| **ERROR** | Incomplete run, baseline suppression, protocol/timeout failure, or invalid explicit library |
| **SKIP** | Missing optional prerequisite; install/build the named dependency |

Important distinctions:

- A started probe that times out or loses protocol integrity is **ERROR**, never PASS
  or SKIP.
- A pure-Wine baseline failure suppresses bridged PASS; fix Wine first.
- `issue_409_local_as_global` on a FAIL annotates the classic offset signature; it
  does not upgrade a FAIL to PASS.

### XWayland separation

Environment capture records two separate facts:

- `display_server` — native session type (`x11` or `wayland`)
- `xwayland_available` — whether an X11 `DISPLAY` exists inside a Wayland session

`suite` prints both. Do not conflate “running under Wayland” with “probe ran on
XWayland”; headless probe runs always use an owned Xvfb display.

### Multi-monitor policy

Automated probe scenarios assume a single X11 coordinate space. Default headless
mode creates one `1280×800` screen. The probe does not skip based on monitor count,
but multi-monitor interactive runs are **unsupported** and may produce misleading
FAIL/ERROR results.

For manual testing, record multi-monitor results as **N/A** unless the window and
pointer were confined to one monitor.

## Manual DAW procedure

### Phase 1: Environment validation

```bash
yabridge-test info --output env.json
wine --version
yabridgectl status
```

### Phase 2: Automated prerequisite + probe

```bash
yabridge-test validate --output validate.json
```

Review `pointer_backend_sanity` (may SKIP when XTEST is absent) and all `probe_*`
scenario results in the JSON output. Live probe scenarios report **ERROR**, not SKIP,
when XTest fails after the X server has started.

### Phase 3: Plugin loading (optional)

```bash
yabridge-test plugin /path/to/plugin.vst3 --output plugin.json
```

Bridge discovery uses canonical Windows metadata targets and managed bridge roots,
never assumes a `.so` beside the Windows plugin file.

### Phase 4: GUI interaction (manual)

With the DAW running:

1. Load plugin in a track
2. Open GUI
3. Click knobs, sliders, buttons, menus, text fields
4. Move and resize the window
5. On multi-monitor setups, test one monitor at a time and note layout in results

### Phase 5: Result recording

| Test | Result | Notes |
|------|--------|-------|
| Probe matrix | pass/fail/error/skip | From `validate` JSON |
| Plugin load | pass/fail/skip | |
| GUI opens | pass/fail | |
| Mouse clicks | pass/fail | Describe offset if any |
| After window move | pass/fail | |
| Multi-monitor | pass/fail/N/A | N/A when not single-screen |

## Known issues

### Wine 10 mouse offset (issue #409)

**Symptom:** clicks register displaced by roughly the window origin.

**Automated detection:** probe FAIL with
`measurements.classification = issue_409_local_as_global` when the signature matches.

**Manual test:**

1. Note window position
2. Click a control center
3. Observe whether the hit target matches

### High DPI

1. Set scaling to 1.5× or 2×
2. Load plugin and compare GUI size and click accuracy
3. Record `dpi_scale` from `yabridge-test info`

### XWayland (manual)

1. Confirm `echo $XDG_SESSION_TYPE` and `$DISPLAY`
2. Compare native X11 session behavior when possible
3. Record both `display_server` and `xwayland_available` from `info`

## Submitting results

Every path creates a **draft** and prints a secret `/complete/{token}` URL.
Edit notes, plugins, and the verdict on that page, then Publish. The harness
never POSTs `/api/v1/results` and never auto-publishes.

```bash
./test.sh submit --session
./test.sh suite --submit
./test.sh probe --submit
yabridge-test suite --output results.json
yabridge-test submit --file results.json
```

Probe `measurements` (coordinates, classifications, assertions) round-trip
through the draft. Paths, log tails, and prefix locations are stripped first.

Include:

- Workarounds that helped
- Reproduction steps
- Wine and yabridge versions/commits
- Whether results came from probe FAIL/ERROR vs manual testing

## Test matrix (manual exploratory)

| Wine | Desktop | Display | Priority |
|------|---------|---------|----------|
| 10.13 | GNOME | Wayland | High |
| 10.13 | KDE | Wayland | High |
| 10.13 | GNOME | X11 | Medium |
| 10.13-staging | KDE | X11 | Medium |
| 9.21 | Any | Any | Baseline |
| 10.x + MR8669 | Any | Any | High |

## Regression testing

When validating a fix:

1. **Baseline** — reproduce on a known-broken configuration
2. **With fix** — rerun the same probe scenario and manual steps
3. **Side effects** — spot-check unrelated configurations

Document exact Wine and yabridge commits, what changed, and whether probe
classifications shifted.
