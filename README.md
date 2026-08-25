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
**copy-on-write clone** of your real Wine prefix, inside a Bubblewrap sandbox
where your production state is mounted read-only. Your original prefix is only
ever *read* — never written, never upgraded, never modified.

Requires `bubblewrap` 0.11+ and a kernel that lets it create namespaces
(unprivileged user namespaces, or a setuid `bwrap`). Without that, the launcher
refuses to start your DAW rather than running it unsandboxed.

```bash
./daw-env.sh reaper
./daw-env.sh bitwig-studio
./daw-env.sh reaper /path/to/project.rpp
./daw-env.sh --fresh reaper            # re-clone the prefix first
./daw-env.sh --prefix ~/.wine reaper   # clone a different real prefix
./daw-env.sh --clean                   # delete prefix-copy/ and exit

# Make one project directory writable inside the sandbox (repeatable)
./daw-env.sh --writable-path ~/Music/projects reaper

# Give the DAW host network access (off by default)
./daw-env.sh --network bitwig-studio
```

**What happens:**
1. Resolves your DAW, requires `bwrap`, and probes the namespaces the sandbox
   needs — all before anything is cloned or generated.
2. Reflink-clones your real prefix (default: `~/.audio-production/winplugins`)
   → `prefix-copy/`. On btrfs/XFS this is copy-on-write: instant, near-zero
   disk, and cloning only *reads* the original.
3. Sources `env.sh` (wine 11.8 + test yabridge on `PATH`), then exports
   `WINEPREFIX` → `prefix-copy/`.
4. Generates yabridge bridges inside `isolation/home/`, an isolated HOME/XDG
   tree that only references the clone.
5. Builds a Bubblewrap argv array and `exec`s it. Your DAW arguments are passed
   through unchanged — no shell re-parses them.

**Why this is safe:** yabridge's `find_wine_prefix()` checks `WINEPREFIX`
first and uses it as an override for *every* plugin, so no plugin resolves
back to a real prefix. Wine 11.8 will auto-upgrade the prefix on first run
(registry + system DLLs) — that upgrade and every plugin write land on COW
extents inside `prefix-copy/`. The original prefix's data blocks are
physically never touched.

**The chain:**
```
generated .so in isolation/home/.vst/yabridge/ (VST_PATH, writable)
  → finds yabridge-host.exe via PATH (our build/yabridge/ is first)
  → yabridge-host.exe wrapper reads $WINELOADER → wine 11.8
  → runs yabridge-host.exe.so with wine 11.8
  → loads Windows plugin DLL, prefix forced to prefix-copy/ via $WINEPREFIX
```

### The sandbox boundary

The DAW runs under `bwrap` in fresh mount, PID, IPC, UTS, cgroup and (by
default) network namespaces, with `--die-with-parent` and `--new-session`.
Bubblewrap applies mounts in order, so every broad mount is followed only by
narrower ones.

| Location | Mode | Why |
|---|---|---|
| `/usr`, `/etc`, `/opt`, `/sys` (+ merged-`/usr` symlinks) | read-only | system libraries and the dynamic loader |
| `/proc`, `/dev` | fresh | kernel interfaces, minimal device set |
| `/tmp` | private tmpfs | host `/tmp` is never visible or writable |
| `/run/user/$UID` | private tmpfs | isolated XDG runtime directory |
| `/dev/snd`, `/dev/dri` | device bind | audio and GPU, only if they exist |
| display/audio sockets | read-only | only the specific X11, Wayland, PulseAudio or PipeWire socket that exists |
| `$XAUTHORITY` | read-only | the one real-home input an X11 session needs |
| project tree (this repo) | read-only | wine 11.8, test yabridge, `env.sh` |
| production Wine prefix | **read-only** | never written, never upgraded |
| `~/.vst`, `~/.vst3`, `~/.clap` | **read-only** | production bridges cannot be modified, and are not on any plugin path. A plugin root that is a symlink is exposed read-only at its canonical target, so storage elsewhere is protected under its real name too |
| DAW install root, `--native-plugin-path` | read-only | the DAW's own files. A `bin` directory is widened to the install root beside it, but never inside your home — a DAW under `~/…/bin` gets that `bin` directory alone |
| `prefix-copy/` | writable | the validated clone |
| `isolation/` | writable | the isolated HOME/XDG and bridge tree |
| `--writable-path DIR` | writable | your projects and rendered output |

Everything else is absent. The real home is never bound as a whole — not even
read-only — and `HOME`, `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_CACHE_HOME`
and `XDG_RUNTIME_DIR` all point inside the sandbox. No D-Bus session socket is
exposed.

**Network:** the sandbox gets its own empty network namespace. Pass
`--network` to give the DAW the host network instead — for example for license
activation — and nothing else changes.

**Writable project paths:** `--writable-path DIR` is repeatable and strict.
`DIR` must be an existing directory given as a canonical absolute path: no
relative paths, no symlinks, no `.`/`..` components, no `:` or newlines, and no
option-looking values. It is rejected when it equals, contains, or sits inside
the production prefix, a production plugin root, a system root, the project
tree, the clone or the isolation tree — under either its own name or the
canonical name of a symlinked plugin root. Outside those writable mounts the DAW
either fails to write or writes into the private tmpfs that disappears with the
run, so save projects and renders into a path you approved.

**Failure diagnostics:**

| Message | Meaning |
|---|---|
| `Error: bwrap was not found in PATH` | install `bubblewrap` 0.11+ |
| `Error: bubblewrap cannot create the namespaces this launcher requires` | kernel policy blocks it. The exact probe commands and what `bwrap` said are printed; enable unprivileged user namespaces (`sudo sysctl -w kernel.unprivileged_userns_clone=1`) or install a setuid `bwrap` |
| `Error: --writable-path overlaps protected state (...)` | the path would make production or invocation-owned state writable |
| `Error: --writable-path must be a canonical path without symlinks` | pass the resolved path, e.g. from `realpath` |
| `Error: '<daw>' was not found in PATH as an executable file` | the DAW is resolved before any mount is planned |
| `Error: the DAW install root would expose the real home (...)` | the DAW binary sits directly in `$HOME`. Move it into its own directory — binding all of `$HOME` read-only is the shortcut this launcher refuses |
| `Error: the production plugin root ... is a symlink that does not resolve` | a dangling `~/.vst`-style symlink. The launcher will not run when it cannot see the bridges it is meant to protect; repair or remove the link |

All of these happen *before* the prefix is cloned, before `yabridgectl` runs
and before the DAW starts.

**Notes:**
- The clone persists between runs (so the one-time wine upgrade isn't
  repeated and plugin state survives). `--fresh` re-clones; `--clean`
  deletes it.
- `prefix-copy/` grows as you use it — COW only shares *unchanged* extents.
- Bridges are generated fresh into `isolation/home/` for each run, and
  `VST_PATH`/`VST3_PATH`/`CLAP_PATH` point there. Your production
  `~/.vst/yabridge/` is mounted read-only, is not on any plugin path, and is
  never synced or rewritten.
- The generated `.so` files are *chainloaders* — thin stubs that locate
  `yabridge-host.exe` on `$PATH` and load the real `libyabridge-*.so` from
  that same directory (`src/chainloader/utils.cpp`). Since `env.sh` puts
  `build/yabridge/` first on `$PATH`, they transparently load the **test
  build's** `libyabridge` *and* host — so this exercises yabridge master in
  full, plugin side and host side.
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
generated .so in isolation/home/.vst/yabridge/ (on VST_PATH)
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

Only one setup may mutate a project at a time. Setup opens `build/` and holds a
`flock` on that directory for its whole run, so a second setup exits instead of
racing the first. Because the lock belongs to the directory *inode* while every
later step addresses `build/` by *path*, setup also records the device and inode
it locked and re-checks them before each mutation phase (stale-candidate
cleanup, Wine download and activation, the yabridge build, and the state file
write). If `build/` was renamed away and a new directory put in its place, setup
aborts rather than writing into a directory it does not own.

That check is a consistency guard, not a security boundary. Bash cannot open
files relative to an already-open directory descriptor, so a small window
remains between each check and the path-based operation that follows it. The
guard is sized for the realistic failure — concurrent or interrupted setups and
leftover state — and anyone who can rename `build/` already runs as your user,
can edit `setup.sh` itself, and is therefore outside what this script can
defend against.

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
clone, generates clone-only bridges into `isolation/home/`, and launches the
DAW inside a Bubblewrap sandbox where the production prefix and production
plugin roots are read-only. No file swaps, no backups, no restore, no traps —
your original prefix is physically never modified.

Flags: `--fresh` (re-clone), `--clean` (delete clone), `--prefix DIR` (clone a
different prefix), `--native-plugin-path DIR` (expose a native plugin
directory read-only, repeatable), `--writable-path DIR` (make one directory
writable inside the sandbox, repeatable), `--network` (give the DAW host
networking instead of an empty network namespace).

`bwrap` and the namespaces it needs are checked before the prefix is cloned
and before any bridge is generated, so an unusable sandbox costs you nothing
and never falls back to an unsandboxed launch. See
[The sandbox boundary](#the-sandbox-boundary) for the full mount table.

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

### bubblewrap cannot create the namespaces this launcher requires

`daw-env.sh` prints the exact probe it ran and what `bwrap` replied. The probe
only executes `/usr/bin/true` — no prefix and no plugin is involved. Either
enable unprivileged user namespaces:

```bash
sudo sysctl -w kernel.unprivileged_userns_clone=1   # persist in /etc/sysctl.d
```

or install a setuid `bwrap` (`bubblewrap-suid` on some distros). The launcher
retries without a user namespace automatically, so a setuid `bwrap` works
without any flag. It will not launch your DAW unsandboxed.

### A home-installed DAW cannot find its own libraries

Outside your home, a DAW at `/opt/Studio/bin/studio` gets all of
`/opt/Studio`, so its sibling `lib/` comes with it. Inside your home nothing is
widened — `~/opt/Studio/bin/studio` gets only `~/opt/Studio/bin` — because the
parent of a `bin` directory in your home is usually a directory like
`~/.local` that holds far more than the DAW. Install such a DAW outside your
home (`/opt` is already read-only in full) rather than loosening the boundary.

### The DAW cannot save a project

Only `prefix-copy/`, `isolation/` and each `--writable-path DIR` are writable.
Pass the project directory explicitly:

```bash
./daw-env.sh --writable-path "$(realpath ~/Music/projects)" reaper
```

The path must be canonical (`realpath` output), must exist, and must not
overlap the production prefix, the production plugin roots, a system root, or
this project tree.

### The DAW has no sound or no window

`/dev/snd`, `/dev/dri` and the display/audio sockets are bound only when they
exist on the host. Check `DISPLAY`, `WAYLAND_DISPLAY`, `XAUTHORITY` and
`XDG_RUNTIME_DIR` are set in the shell you launch from — the sandbox binds the
specific socket those variables name, and nothing else.

### License activation fails

The sandbox has no network by default. Run the activation once with
`./daw-env.sh --network <daw>`.

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
