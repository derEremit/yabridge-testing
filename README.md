# Yabridge Staging — Isolated Test Infrastructure

Build and test **yabridge git master** with a **pinned, digest-verified
wine-staging build** in complete
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
| test harness | `test-harness/` | venv, not system |

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
│   ├── yabridge-src/  # git clone (kept for rebuilding)
│   └── component-state.env  # recorded wine + yabridge identities
├── prefix/           # isolated WINEPREFIX (created by setup.sh)
├── prefix-copy/      # COW clone of your real prefix (created by daw-env.sh)
├── isolation/        # isolated HOME/XDG + bridges (created by daw-env.sh)
│   └── home/         # generated bridges, on VST_PATH/VST3_PATH/CLAP_PATH
├── run-state/        # created by daw-env.sh, never writable inside the sandbox
│   └── run-manifest.json  # what the last launch actually was
├── test-harness/     # Python test harness CLI
├── probe/            # coordinate probe fixtures
├── packer/           # VM image templates
├── ansible/          # provisioning
├── install.sh        # bootstrap clone/tarball
├── docs/
└── tests/
```

## Setup

### First time

```bash
git clone https://github.com/derEremit/yabridge-staging
cd yabridge-staging
```

Installing Wine means running bytes fetched over the network, so `setup.sh`
will not install Wine until you have told it *which* release you want and what
that release's SHA-256 is. It never derives the expected digest from the file
it just downloaded: hashing whatever arrived would only prove the transfer was
intact, which is a different question from whether these are the bytes anyone
intended to run.

Choosing that digest is your job, and it is the one step this project cannot do
for you:

1. Pick a release at
   <https://github.com/Kron4ek/Wine-Builds/releases> and note its version, for
   example `11.8`. The archive is `wine-<version>-staging-amd64.tar.xz`.
2. Obtain the SHA-256 of that archive from a source you trust — the release
   page, a signed checksum file, a copy you already verified on another
   machine, or a colleague who did. Do not take it from an unverified download
   on the machine you are about to install onto.
3. Run setup with both:

```bash
./setup.sh --wine-version 11.8 --wine-sha256 <64-character-sha256>
```

Or skip Wine entirely and keep using the system installation:

```bash
./setup.sh --no-wine
```

Setup will:
1. Install build deps (`base-devel`, `meson`, `ninja`, `wine`, `libxcb`)
2. Download the Wine release you named, compare it against the digest you gave,
   and only then atomically activate it at `build/wine/`
3. Clone yabridge git master → `build/yabridge-src/`
4. Build with meson/ninja → `build/yabridge/`
5. Create `test-harness/.venv` and install the local
   harness package
6. Generate `env.sh` and `test.sh`
7. Initialize an isolated WINEPREFIX at `prefix/`

A mismatch installs nothing and leaves any working Wine exactly where it was.
Success records `WINE_SHA256_VERIFIED=true` in `build/component-state.env`, and
that record is what a launch requires: state that merely repeats a hash
somebody observed is treated as no record at all, and the archive is fetched and
compared again.

### Update components

```bash
# Rebuild yabridge from latest master, leaving Wine alone
./setup.sh --no-wine

# Move to a different Wine release (re-downloads and re-verifies)
./setup.sh --no-yabridge --wine-version 11.9 --wine-sha256 <64-character-sha256>

# Build a specific yabridge branch
./setup.sh --yabridge-branch develop --no-wine
```

## Usage

### Safe: test harness only (no DAW)

Runs the `yabridge-test` CLI from `test-harness/` using the
isolated wine + yabridge. Your system yabridge is never touched.

```bash
./test.sh info              # collect environment info
./test.sh probe --scenario offset --samples 3 --json
./test.sh validate          # pointer prerequisite + bridged coordinate matrix
./test.sh suite             # full test suite
./test.sh plugin ~/foo.vst3 # test a specific plugin
```

The deterministic coordinate probe is a Windows CLAP fixture exercised first
under pure Wine and then through yabridge. It uses temporary Wine prefixes and
headless X servers by default; an existing display is touched only with
`--no-headless --allow-pointer-warp`. Missing optional prerequisites produce
`SKIP`, harness failures produce `ERROR`, and completed coordinate mismatches
produce `FAIL`; all unsuccessful or empty executions exit nonzero.

Build the pinned native and MinGW probe artifacts before running `probe` or
`validate`. Exact dependencies, build commands, scenario semantics, raw
measurements, and troubleshooting are documented in
[the coordinate probe guide](./docs/coord-probe.md).

### Launch a DAW against a COW clone of your real prefix

`daw-env.sh` runs your DAW with wine 11.8 + test yabridge, pointed at a
**copy-on-write clone** of your real Wine prefix, inside a Bubblewrap sandbox
where your production state is mounted read-only.

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

# Silence Wine's own diagnostics (kept by default)
./daw-env.sh --quiet-wine reaper
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
5. Builds a Bubblewrap argv array, then re-checks every identity the run
   depends on and records it in `run-state/run-manifest.json`.
6. `exec`s the sandbox. Your DAW arguments are passed through unchanged — no
   shell re-parses them.

**Why this is safe:** the launcher refuses to start without `bwrap`.
Production prefix and plugin roots are mounted read-only, and the bridges
used for the run resolve inside the clone. Wine 11.8 will auto-upgrade the
prefix on first run (registry + system DLLs) — that upgrade and every
plugin write land on COW extents inside `prefix-copy/`. `WINEPREFIX` is how
Wine finds that clone; it is not the isolation boundary.

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
| `run-state/` | read-only | inside the project tree, so the DAW cannot rewrite the record of its own run |
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

**Native plugin directories:** `--native-plugin-path DIR` is repeatable and
held to the same standard, for two reasons at once. The directory is bound
read-only *and* placed on the DAW's plugin search path, so a broad value both
shadows the narrower mounts already planned and can put production bridges back
in front of the DAW. `DIR` must be an existing canonical directory, and it is
rejected when it is the filesystem root, at or above your real home, at or
above anything the sandbox creates for itself (`/proc`, `/dev`, `/tmp`, the XDG
runtime directory, the display socket directory), or overlapping the production
prefix, a production plugin root, the project tree, the clone or the isolation
tree — under either its own name or the canonical name of a symlinked plugin
root. A directory *inside* a system root the sandbox already binds read-only in
full, such as `/usr/lib/vst3`, is allowed: it adds no mount and shadows
nothing. Every one of these refusals happens before the prefix is cloned.

**Failure diagnostics:**

| Message | Meaning |
|---|---|
| `Error: bwrap was not found in PATH` | install `bubblewrap` 0.11+ |
| `Error: bubblewrap cannot create the namespaces this launcher requires` | kernel policy blocks it. The exact probe commands and what `bwrap` said are printed; enable unprivileged user namespaces (`sudo sysctl -w kernel.unprivileged_userns_clone=1`) or install a setuid `bwrap` |
| `Error: --writable-path overlaps protected state (...)` | the path would make production or invocation-owned state writable |
| `Error: --writable-path must be a canonical path without symlinks` | pass the resolved path, e.g. from `realpath` |
| `Error: --native-plugin-path would shadow the sandbox mount at ...` | the directory is at or above something the sandbox creates for itself; name the plugin directory itself |
| `Error: --native-plugin-path overlaps protected state (...)` | the directory would expose production bridges or invocation-owned state to the DAW |
| `Error: the source prefix is inside project state (...)` | `--prefix` names something in this repo, its clone or its isolation tree; clone a prefix that lives outside the project |
| `Error: component state does not record WINE_SHA256_VERIFIED=true` | the installed Wine was never compared against a digest you chose. Reinstall with `./setup.sh --wine-version <version> --wine-sha256 <digest>` |
| `Error: '<daw>' was not found in PATH as an executable file` | the DAW is resolved before any mount is planned |
| `Error: the DAW install root would expose the real home (...)` | the DAW binary sits directly in `$HOME`. Move it into its own directory — binding all of `$HOME` read-only is the shortcut this launcher refuses |
| `Error: the production plugin root ... is a symlink that does not resolve` | a dangling `~/.vst`-style symlink. The launcher will not run when it cannot see the bridges it is meant to protect; repair or remove the link |

All of these happen *before* the prefix is cloned, before `yabridgectl` runs
and before the DAW starts.

### The run manifest

A sandbox is only worth as much as your ability to say what ran inside it.
Before the DAW starts — and after every other check has passed — the launcher
writes `run-state/run-manifest.json`, the record of what the run *actually*
was:

```json
{
  "bridge_home": "/home/you/yabridge-staging/isolation/home",
  "bridge_roots": [
    "/home/you/yabridge-staging/isolation/home/.vst/yabridge",
    "/home/you/yabridge-staging/isolation/home/.vst3/yabridge",
    "/home/you/yabridge-staging/isolation/home/.clap/yabridge"
  ],
  "clone_device": 66308,
  "clone_inode": 8412737,
  "clone_path": "/home/you/yabridge-staging/prefix-copy",
  "daw_executable": "/usr/bin/reaper",
  "generated_at": "2026-08-25T18:24:07Z",
  "sandbox": {
    "bwrap": "/usr/bin/bwrap",
    "enabled": true,
    "namespace_mode": "user",
    "network": false
  },
  "schema_version": 1,
  "source_device": 66308,
  "source_inode": 8409281,
  "source_path": "/home/you/.audio-production/winplugins",
  "wine_diagnostics": {
    "quiet": false,
    "winedebug": null
  },
  "wine_executable": "/home/you/yabridge-staging/build/wine/bin/wine",
  "wine_installed_version": "11.8",
  "wine_requested_version": "11.8",
  "wine_digest_verified": true,
  "wine_sha256": "6c6f642b0954248493ebbd86ec232c46a6b9cf97c747ab3f1bcb707a22efed1d",
  "wine_version_string": "wine-11.8 (Staging)",
  "yabridge_commit": "48ea9749b682c48875366134a42073d6b3d0a8c4",
  "yabridge_home": "/home/you/yabridge-staging/build/yabridge",
  "yabridge_requested_ref": "master",
  "yabridgectl_path": "/home/you/yabridge-staging/build/yabridge/yabridgectl"
}
```

Keys are sorted and the file always ends with a newline, so two runs are easy to
`diff`. `namespace_mode` is `user` or `setuid` — whichever the sandbox command
that was actually verified uses.

Every recorded path is the canonical one. Components are resolved to the objects
they name before anything uses them, so a project kept behind a symlink, a Wine
build reached through a linked directory, or a packaged `yabridgectl` that is a
symlink into a versioned directory all launch normally and are recorded as what
they resolve to. `setup.sh` does the same for its own location, so `env.sh` and
`test.sh` name the directory the files really live in.

Every value is re-derived at write time rather than copied from what an earlier
phase believed:

- the source device and inode come from the clone's own provenance record, and
  the recorded path must still be that exact filesystem object;
- the clone must still be the directory that was validated earlier in the run —
  a clone swapped after validation is refused;
- the Wine executable is asked for its version again, and it must match the
  version `setup.sh` recorded in `build/component-state.env`;
- `wine_digest_verified` is only ever `true`, because a launch requires
  `WINE_SHA256_VERIFIED=true` in component state and refuses otherwise. The
  field is written so a manifest read later says on its own terms that the Wine
  it names was compared against a digest a person chose;
- component state is *parsed*, never sourced, so nothing in that file can run
  as shell code;
- the bridge roots must canonicalize inside `isolation/`;
- the sandbox fields are read out of the finished `bwrap` argv, so
  `network: false` means that command really does unshare the network. An
  inherited environment variable cannot claim otherwise.

The document is built by a short embedded Python encoder that receives each
value as an environment variable — no shell text is ever interpolated into
JSON — writes a private sibling temporary, flushes and `fsync`s it, and
atomically renames it over the old manifest. So the file is always a complete
document: either the new one or the one before it. A symlinked
`run-manifest.json` is refused rather than followed, and a failed write removes
only the temporary this invocation created.

The manifest lives in `run-state/` rather than in `isolation/` because
`isolation/` is writable inside the sandbox and the project tree is not. The
DAW the manifest describes can read its own record and cannot change it: an
attempt to rewrite, append to, truncate or unlink it fails with `EROFS`, and
the file's checksum is the same after the run as it was when the DAW started.

**If the manifest cannot be written, the DAW does not start.** That is
deliberate: a run nobody can identify afterwards is exactly the run you will
want to identify. The error names the field that could not be proven, and the
manifest from your previous launch is left intact. Whether the components were
recorded at all is checked before the prefix is cloned, so a project that never
ran `./setup.sh` is refused without leaving a clone or a bridge tree behind.

### Wine diagnostics

Wine's warnings and crash traces are how you find out why a plugin failed, so
nothing here silences them for you. `setup.sh` no longer writes
`WINEDEBUG=-all` into `env.sh`, and the launcher invents no value of its own:

| You run | The DAW gets |
|---|---|
| `./daw-env.sh reaper` | `WINEDEBUG` unset — Wine's defaults |
| `WINEDEBUG=+relay ./daw-env.sh reaper` | `WINEDEBUG=+relay`, exactly as you set it |
| `./daw-env.sh --quiet-wine reaper` | `WINEDEBUG=-all` |
| `WINEDEBUG=+relay ./daw-env.sh --quiet-wine reaper` | `WINEDEBUG=-all` — the option wins |

The manifest records both facts separately: `quiet` is true only when you
passed `--quiet-wine`, and `winedebug` is the value the DAW actually received
(`null` when unset). Exporting `WINEDEBUG=-all` yourself therefore shows up as
an inherited setting, not as the option — an inherited variable cannot
impersonate a command-line decision.

Setup still runs its own one-off `wineboot` quietly, because that output is
noise from a step you did not ask about.

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

No system wine binary is involved in either case. With `./daw-env.sh`, the
production prefix is mounted read-only and writes go to the clone.

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
- `--wine-version <ver>` — the wine release to install; required unless
  `--no-wine`. Must be a plain version token, so it can never name a path
- `--wine-sha256 <digest>` — the SHA-256 that release is expected to have;
  required unless `--no-wine`. Compared before extraction
- `--yabridge-branch <ref>` — build a specific branch/commit (default: master)
- `--no-wine` — skip wine (rebuild yabridge only)
- `--no-yabridge` — skip yabridge (re-download wine only)
- `-h` / `--help` — usage

There is no default wine version and no way to have setup supply the digest for
you. See [First time](#first-time) for why, and for where to get a digest you
can trust.

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

That lock covers setup against setup. It does not cover setup against a launch
already in flight: `daw-env.sh` resolves and records the exact Wine and
yabridge executables it will use, but a `setup.sh` that atomically replaces
`build/wine` in the window between that resolution and `exec` would leave the
manifest naming a path whose contents have since changed. Closing that properly
means holding the build lock across a whole DAW session, which would make a
running DAW block every setup — a worse trade than the race. Do not run
`./setup.sh` while a DAW is running, and if you do, treat that session's
manifest as describing what was resolved rather than what finished the run.

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

It deliberately does not set `WINEDEBUG`: Wine's diagnostics belong to whoever
launches Wine. `daw-env.sh` applies its own diagnostics policy *after* sourcing
`env.sh`, so an older generated `env.sh` that still exports `WINEDEBUG=-all`
cannot silence your DAW — but regenerate it anyway if you source it by hand.

### `test.sh`

Wrapper around the exact
`test-harness/.venv/bin/yabridge-test` installed by
`setup.sh`. It checks that `env.sh` and the venv entrypoint exist, sources the
isolated environment, and passes all arguments through. It never falls back to
a globally installed command.

### `daw-env.sh`

Safe DAW launcher. Reflink-clones your real Wine prefix into `prefix-copy/`,
exports `WINEPREFIX` to the clone, generates clone-only bridges into
`isolation/home/`, and launches the DAW inside a Bubblewrap sandbox. The
launcher refuses to start without `bwrap`; production prefix and plugin
roots are mounted read-only; bridges used for the run resolve inside the
clone. `WINEPREFIX` is not the isolation boundary.

Flags: `--fresh` (re-clone), `--clean` (delete clone), `--prefix DIR` (clone a
different prefix), `--native-plugin-path DIR` (expose a native plugin
directory read-only, repeatable), `--writable-path DIR` (make one directory
writable inside the sandbox, repeatable), `--network` (give the DAW host
networking instead of an empty network namespace), `--quiet-wine` (set
`WINEDEBUG=-all` for the DAW instead of leaving diagnostics alone).

`bwrap` and the namespaces it needs are checked before the prefix is cloned
and before any bridge is generated, so an unusable sandbox costs you nothing
and never falls back to an unsandboxed launch. See
[The sandbox boundary](#the-sandbox-boundary) for the full mount table.

Every launch records its exact identity in `run-state/run-manifest.json` after
the last check passes and before the DAW starts; if it cannot be recorded, the
DAW does not run. See [The run manifest](#the-run-manifest).

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

### The launcher refuses because it cannot record the run

Messages like `Error: run manifest: …` mean an identity the manifest must
record could not be proven — most often `env.sh` or `build/component-state.env`
is missing (run `./setup.sh`), the Wine executable no longer reports the version
setup recorded (re-run `./setup.sh --no-yabridge`), or `prefix-copy/` is no
longer the clone whose provenance was validated (`./daw-env.sh --fresh <daw>`).
The first two are checked before the prefix is cloned, so they cost nothing. The
DAW is not started and `run-state/run-manifest.json` from your last successful
launch is left untouched.

If the message says the destination is a symlink or is not a regular file,
something replaced `run-state/run-manifest.json` — the launcher will not write
through it, because this run's provenance would land wherever that points. The
refusal prints what to look at and what to remove:

```bash
ls -l -- run-state/run-manifest.json   # see what it actually is
rm -- run-state/run-manifest.json      # only if it is the link, not your data
```

The next launch writes a fresh manifest. Nothing else in `run-state/` is
touched.

### Wine output is too noisy, or too quiet

Wine's diagnostics are no longer suppressed for you. Pass `--quiet-wine` for a
silent run, or set `WINEDEBUG` yourself (`WINEDEBUG=+relay ./daw-env.sh reaper`)
— see [Wine diagnostics](#wine-diagnostics). Check
`run-state/run-manifest.json` if you want to know which of the two the last run
actually used.

### License activation fails

The sandbox has no network by default. Run the activation once with
`./daw-env.sh --network <daw>`.

### Wayland + xdotool

Mouse coordinate tests (`yabridge-test probe`; `validate` is a secondary
pointer) may not work under pure Wayland because `xdotool` depends on XTest.
Run under X11 or XWayland.

### Portability

`setup.sh` auto-installs deps only on pacman-based distros (Arch, Garuda,
Manjaro). On apt/dnf distros it prints a reminder — install the equivalents
manually.

## Residual risks

- Isolation is a Bubblewrap sandbox, not a VM. Paths that are not in the
  mount table are not protected by it. A kernel that blocks user namespaces,
  or a plugin that talks to something outside the sandbox, can still escape
  what the launcher enforces.
- Plugin/DAW installer URLs in Ansible are version-pinned only; vendors
  published no digests (Phase 5).
- Packer templates still contain a build-time password hash / SSH password
  so the image can be provisioned; the last provisioner locks those
  accounts before the published disk is written.
- No Python lockfiles and no Docker image digest.
- This repository is the public test tree: isolation, harness, probe,
  Packer, and Ansible. The results server source is private. Submit
  results to the live site at https://yabridge-tests.fly.dev.
  Upstream `robbert-vdh/yabridge` is never modified here
  (`build/yabridge-src` is an untracked clone).

## Checks

`./scripts/check.sh` runs shellcheck on the parent scripts, the bats suite,
and the harness pytest suite when that venv exists.

## Related

- [yabridge](https://github.com/robbert-vdh/yabridge) — the plugin bridge
- [Kron4ek Wine-Builds](https://github.com/Kron4ek/Wine-Builds) — prebuilt wine
  binaries
- [Issue #409](https://github.com/robbert-vdh/yabridge/issues/409) — Wine 10
  embedding discussion
