# Yabridge Staging — Isolated Test Infrastructure

Build and test **yabridge git master** with **latest wine-staging** in complete
isolation. No system files are touched — everything lives in `build/`,
`prefix/`, and `prefix-copy/`. Your existing yabridge + wine setup (e.g. wine
9.21) and your real Wine prefixes stay untouched.

## Problem

- yabridge 5.1.1 stable only works with wine ≤ 9.21
- git master has fixes for wine 10.x but needs building from source
- Latest wine-staging keeps moving forward
- You want to test new combinations without breaking your daily driver

## What This Does

| Component | Source | Installed To |
|---|---|---|
| yabridge | [git master](https://github.com/robbert-vdh/yabridge) | `build/yabridge/` |
| wine-staging | [Kron4ek prebuilt](https://github.com/Kron4ek/Wine-Builds) | `build/wine/` |
| WINEPREFIX | isolated | `prefix/` |
| test harness | `yabridge-test-infra/` | venv, not system |

## Directory Layout

```
.
├── setup.sh          # Full setup: build yabridge + download wine
├── env.sh            # Environment overrides (generated, gitignored)
├── test.sh           # Run test-harness with isolated env
├── daw-env.sh        # Launch a DAW against a COW clone of your real prefix
├── .gitignore
├── README.md
├── build/
│   ├── wine/         # wine-11.8-staging (no system install)
│   │   └── bin/wine  # WINELOADER target
│   ├── yabridge/     # yabridge git master
│   │   ├── libyabridge-vst2.so / -vst3.so / -clap.so
│   │   ├── libyabridge-chainloader-*.so
│   │   ├── yabridge-host.exe        # wrapper script
│   │   └── yabridge-host.exe.so     # actual winelib binary
│   └── yabridge-src/  # git clone (kept for rebuilding)
├── prefix/           # isolated WINEPREFIX (created by setup.sh)
├── prefix-copy/      # COW clone of your real prefix (created by daw-env.sh)
└── yabridge-test-infra/
    └── test-harness/  # Python test harness CLI
```

## Setup

### First time

```bash
./setup.sh
```

This will:
1. Install build deps (`base-devel`, `meson`, `ninja`, `wine`, `libxcb`)
2. Fetch latest wine-staging from Kron4ek → verify and atomically activate it
   at `build/wine/`
3. Clone yabridge git master → `build/yabridge-src/`
4. Build with meson/ninja → `build/yabridge/`
5. Create `yabridge-test-infra/test-harness/.venv` and install the local
   harness package
6. Generate `env.sh` and `test.sh`
7. Initialize an isolated WINEPREFIX at `prefix/`

### Update components

```bash
# Rebuild yabridge from latest master
./setup.sh --no-wine

# Update wine to latest staging (will re-download)
./setup.sh --no-yabridge

# Pin a specific wine version and verify the downloaded archive
./setup.sh --wine-version 11.7 --wine-sha256 <64-character-sha256>

# Build a specific yabridge branch
./setup.sh --yabridge-branch develop
```

## Usage

### Safe: test harness only (no DAW)

Runs the `yabridge-test` CLI from `yabridge-test-infra/test-harness/` using the
isolated wine + yabridge. Your system yabridge is never touched.

```bash
./test.sh info              # collect environment info
./test.sh validate          # mouse coordinate validation
./test.sh suite             # full test suite
./test.sh plugin ~/foo.vst3 # test a specific plugin
```

### Launch a DAW against a COW clone of your real prefix

`daw-env.sh` runs your DAW with wine 11.8 + test yabridge, pointed at a
**copy-on-write clone** of your real Wine prefix. Your original prefix is
only ever *read* — never written, never upgraded, never modified.

```bash
./daw-env.sh reaper
./daw-env.sh bitwig-studio
./daw-env.sh reaper /path/to/project.rpp
./daw-env.sh --fresh reaper            # re-clone the prefix first
./daw-env.sh --prefix ~/.wine reaper   # clone a different real prefix
./daw-env.sh --clean                   # delete prefix-copy/ and exit
```

**What happens:**
1. Reflink-clones your real prefix (default: `~/.audio-production/winplugins`)
   → `prefix-copy/`. On btrfs/XFS this is copy-on-write: instant, near-zero
   disk, and cloning only *reads* the original.
2. Sources `env.sh` (wine 11.8 + test yabridge on `PATH`), then exports
   `WINEPREFIX` → `prefix-copy/`.
3. Launches your DAW via `exec`. No traps, no cleanup — nothing to fail.

**Why this is safe:** yabridge's `find_wine_prefix()` checks `WINEPREFIX`
first and uses it as an override for *every* plugin, so no plugin resolves
back to a real prefix. Wine 11.8 will auto-upgrade the prefix on first run
(registry + system DLLs) — that upgrade and every plugin write land on COW
extents inside `prefix-copy/`. The original prefix's data blocks are
physically never touched.

**The chain:**
```
existing .so in ~/.vst/yabridge/
  → finds yabridge-host.exe via PATH (our build/yabridge/ is first)
  → yabridge-host.exe wrapper reads $WINELOADER → wine 11.8
  → runs yabridge-host.exe.so with wine 11.8
  → loads Windows plugin DLL, prefix forced to prefix-copy/ via $WINEPREFIX
```

**Notes:**
- The clone persists between runs (so the one-time wine upgrade isn't
  repeated and plugin state survives). `--fresh` re-clones; `--clean`
  deletes it.
- `prefix-copy/` grows as you use it — COW only shares *unchanged* extents.
- No `yabridgectl sync` needed. The `.so` files in `~/.vst/yabridge/` (etc.)
  are *chainloaders* — thin stubs that locate `yabridge-host.exe` on `$PATH`
  and load the real `libyabridge-*.so` from that same directory
  (`src/chainloader/utils.cpp`). Since `env.sh` puts `build/yabridge/` first
  on `$PATH`, your existing chainloaders transparently load the **test
  build's** `libyabridge` *and* host — so this exercises yabridge master in
  full, plugin side and host side, while `~/.vst/yabridge/` stays untouched.
- Requires the project dir and the real prefix on the same btrfs/XFS
  filesystem. If reflink isn't available the script aborts loudly rather
  than doing a full multi-GB copy.

### Advanced: manual env (use with care)

```bash
source env.sh                # sets WINELOADER, PATH, LD_LIBRARY_PATH
yabridge-test info           # runs with wine 11.8
yabridge-wine winecfg        # configure the test WINEPREFIX
```

**Don't launch your DAW after `source env.sh`** — `WINEPREFIX` is set to the
isolated `prefix/` which has no plugins installed. Use `daw-env.sh` instead
(it overrides `WINEPREFIX` to a COW clone of your real prefix).

## How the isolation works

### Environment variables

| Variable | Points to | Effect |
|---|---|---|
| `WINELOADER` | `build/wine/bin/wine` | yabridge runs plugins with wine 11.8 |
| `WINESERVER` | `build/wine/bin/wineserver` | wine server from 11.8 |
| `WINEDLLPATH` | `build/wine/lib{,64}/wine` | wine DLLs from 11.8 |
| `WINEPREFIX` | `prefix/` | isolated prefix, not `~/.wine` |
| `PATH` | `build/wine/bin` + `build/yabridge/` first | both custom tools found first |
| `LD_LIBRARY_PATH` | `build/wine/lib{,64}` | custom wine shared libs |

### yabridge-host.exe chain

When using `./daw-env.sh reaper` (WINEPREFIX → `prefix-copy/`):
```
existing .so in ~/.vst/yabridge/
  → finds yabridge-host.exe on PATH (our build/yabridge/ is first)
  → yabridge-host.exe wrapper reads $WINELOADER (our build/wine/bin/wine)
  → runs yabridge-host.exe.so with wine 11.8
  → loads Windows plugin DLL, prefix forced to prefix-copy/ via $WINEPREFIX
```

When using `./test.sh info` (WINEPREFIX → `prefix/`):
```
yabridge .so
  → finds yabridge-host.exe on PATH
  → uses $WINELOADER → wine 11.8
  → runs yabridge-host.exe.so
  → loads from $WINEPREFIX (prefix/ — isolated, no real plugins)
```

No system wine binary is involved in either case, and no real Wine prefix
is ever written to.

## Test harness integration

The test harness (`yabridge-test`) detects:

- **Wine version**: runs `wine --version` → picks up our wine 11.8
- **Yabridge version**: reads `yabridge-host.exe --version` → our git master
- **Staging status**: auto-detected from wine version string

Verified output:

```
Wine Version      11.8 (Staging)     # ← not system wine 9.21
Wine Staging      Yes
Yabridge Version  5.1.1              # ← git master @ 48ea974
```

## Files reference

### `setup.sh`

Idempotent. Skips already-completed steps. Flags:
- `--wine-version <ver>` — pin a specific wine version (default: latest-staging)
- `--wine-sha256 <digest>` — required with `--wine-version`; verifies the
  archive before extraction
- `--yabridge-branch <ref>` — build a specific branch/commit (default: master)
- `--no-wine` — skip wine (rebuild yabridge only)
- `--no-yabridge` — skip yabridge (re-download wine only)
- `-h` / `--help` — usage

Wine archives are rejected if their digest does not match or if any entry uses
an absolute or parent-traversing path. Extraction and executable validation
happen in a candidate directory. A verified candidate is atomically exchanged
with an existing install, so a failed refresh or interrupted activation leaves
the working Wine installation active.

Build deps checked on pacman-based distros. On other distros, ensure you have:
`gcc >= 10`, `meson`, `ninja`, `wine` + `winegcc`, `libxcb-dev`.

### `env.sh`

Generated by `setup.sh`. Contains absolute paths. Sourced by `test.sh` and
`daw-env.sh`. Listed in `.gitignore` — regenerate with `./setup.sh --no-wine --no-yabridge`.

### `test.sh`

Wrapper around the exact
`yabridge-test-infra/test-harness/.venv/bin/yabridge-test` installed by
`setup.sh`. It checks that `env.sh` and the venv entrypoint exist, sources the
isolated environment, and passes all arguments through. It never falls back to
a globally installed command.

### `daw-env.sh`

Safe DAW launcher. Reflink-clones your real Wine prefix into `prefix-copy/`
(copy-on-write — the original is only read), exports `WINEPREFIX` to the
clone, and launches the DAW with wine 11.8 + test yabridge. No file swaps,
no backups, no restore, no traps — your original prefix is physically never
modified. Flags: `--fresh` (re-clone), `--clean` (delete clone),
`--prefix DIR` (clone a different prefix).

## Troubleshooting

### yabridge-host.exe not found

Ensure `build/yabridge/yabridge-host.exe` exists after setup. If not, rerun
`./setup.sh --no-wine` to rebuild just yabridge.

### WINEPREFIX not initialized

```bash
source env.sh && yabridge-wine winecfg
```

Close winecfg when done. The prefix is now ready.

### Build fails

- You need `winegcc` (from system `wine` package) — this is the cross-compiler
  for the Windows host component.
- GCC >= 10 required.
- If `meson` can't find dependencies, install the -dev packages for your distro.

### Wayland + xdotool

Mouse coordinate tests (`yabridge-test validate`) may not work under pure
Wayland because `xdotool` depends on XTest. Run under X11 or XWayland.

### Portability

`setup.sh` auto-installs deps only on pacman-based distros (Arch, Garuda,
Manjaro). On apt/dnf distros it prints a reminder — install the equivalents
manually.

## Related

- [yabridge](https://github.com/robbert-vdh/yabridge) — the plugin bridge
- [yabridge-test-infra](./yabridge-test-infra/) — VM-based testing (Packer,
  Ansible, results server)
- [Kron4ek Wine-Builds](https://github.com/Kron4ek/Wine-Builds) — prebuilt wine
  binaries
- [Issue #409](https://github.com/robbert-vdh/yabridge/issues/409) — Wine 10
  embedding discussion
