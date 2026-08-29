# Launching a DAW against a clone of your real prefix

`daw-env.sh` runs your DAW with the pinned Wine build and the test yabridge,
pointed at a **copy-on-write clone** of your real Wine prefix, inside a
Bubblewrap sandbox. This document is the full reference: the command forms,
what happens in which order, the exact mount table, network identity
(`--mac`), the run manifest, and Wine diagnostics. The short version is in
the [README](../README.md#launch-a-daw-against-a-clone-of-your-real-prefix);
the XLN installer procedure is in [xln-isolated-installer.md](xln-isolated-installer.md).

## Command forms

```bash
# Clone-only installer (daw-env rewrites this path; two restarts are OK)
./daw-env.sh --mac "$XLN_MAC" --nic "$XLN_NIC" --address "$XLN_ADDR" \
  --writable-path "$(realpath -- "$BITWIG_PROJECTS")" \
  "$PWD/build/wine/bin/wine" \
  "C:\\ProgramData\\XLN Audio\\Temp\\App\\Cotton XLN Online Installer\\updateBinary\\XLN Online Installer.exe"

# Bitwig after that (same identity)
./daw-env.sh --refresh-bridges --mac "$XLN_MAC" --nic "$XLN_NIC" \
  --address "$XLN_ADDR" \
  --writable-path "$(realpath -- "$BITWIG_PROJECTS")" \
  bitwig-studio
```

`daw-env.sh` runs your DAW with the pinned wine-staging + test yabridge, pointed at a
**copy-on-write clone** of your real Wine prefix, inside a Bubblewrap sandbox.
Only the Wine prefix and yabridge bridges are isolated. The DAW's `HOME` is
your **real login home**, so Bitwig opens `~/.BitwigStudio` (not
`isolation/home/.BitwigStudio`, not `/root/.BitwigStudio`). Isolated XDG
keeps yabridgectl from writing production config. Isolated runs write Bitwig
settings and Wine known folders back to the host.

Requires `bubblewrap` 0.11+ and a kernel that lets it create namespaces
(unprivileged user namespaces, or a setuid `bwrap`). `--mac` also needs
`unshare` plus `pasta` (from the `passt` package; preferred) or
`slirp4netns`. Without that, the launcher refuses to start your DAW rather
than running it unsandboxed or silently dropping `--mac`.

```bash
./daw-env.sh reaper
./daw-env.sh bitwig-studio
./daw-env.sh reaper /path/to/project.rpp
./daw-env.sh --fresh reaper            # re-clone the prefix first
./daw-env.sh --prefix ~/.wine reaper   # clone a different real prefix
./daw-env.sh --copy reaper             # if reflink fails, full-copy (maybe huge)
./daw-env.sh --clean                   # delete prefix-copy/ and exit

# Make one project directory writable inside the sandbox (repeatable)
./daw-env.sh --writable-path ~/Music/projects reaper

# Give the DAW host network access (off by default)
./daw-env.sh --network bitwig-studio

# Recommended Bitwig launch (reuse the clone; omit --fresh unless you want a new one)
./daw-env.sh --refresh-bridges --mac "$XLN_MAC" --nic "$XLN_NIC" \
  --address "$XLN_ADDR" \
  --writable-path "$(realpath -- "$BITWIG_PROJECTS")" \
  bitwig-studio

# XLN / AD2 Computer ID: pasta from the host, attached to a netns we own.
./daw-env.sh --mac "$XLN_MAC" --nic "$XLN_NIC" --address "$XLN_ADDR" \
  bitwig-studio
./daw-env.sh --writable-path "$(realpath -- "$HOME/Bitwig Studio")" \
  ~/.local/bin/xln-fj bitwig-studio

# Clone-only XLN Online Installer (authorizes prefix-copy, not production)
./daw-env.sh --mac "$XLN_MAC" --nic "$XLN_NIC" --address "$XLN_ADDR" \
  --writable-path "$(realpath -- "$BITWIG_PROJECTS")" \
  "$PWD/build/wine/bin/wine" \
  "C:\\Program Files\\XLN Audio\\XLN Online Installer\\XLN Online Installer.exe"

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
   `WINEPREFIX` → `prefix-copy/` on the host.
4. Generates yabridge bridges inside `isolation/home/`. Isolated generation
   calls `yabridgectl add` **once per plugin directory** (so paths with
   spaces stay one argument). Only the clone is registered.
5. Builds a Bubblewrap argv array: the clone is bound **over** the production
   prefix path so Bitwig keeps the VST/VST3/CLAP path strings it already
   indexed; isolated yabridge overlays the resolved `~/.vst/yabridge`,
   `~/.vst3/yabridge` and `~/.clap/yabridge` directories. A `~/winplugins` or
   `~/.vst` symlink stays a symlink — Bubblewrap cannot mount onto one.
   Inside the sandbox `WINEPREFIX` is that production path. Then it records
   the run in `run-state/run-manifest.json`.
6. Starts the DAW through Bubblewrap. Your DAW arguments are passed through
   unchanged — no shell re-parses them. With `--mac`, the launcher
   `unshare`s a user+net namespace it owns, starts `pasta --config-net
   --mac-addr …` from the **host** netns (attached with `--userns` /
   `--netns /proc/<pid>/ns/net`) or slirp4netns, then runs real `bwrap`
   inside that netns (no `--unshare-net`, no cross-userns `nsenter`).
   Starting pasta after `unshare --net` makes it fall back to 169.254
   local-mode, which breaks XLN and other outbound plugin traffic.

**Why this is safe:** the launcher refuses to start without `bwrap`.
Production prefix and plugin roots are mounted read-only, and the bridges
used for the run resolve inside the clone. Wine 11.8 will auto-upgrade the
prefix on first run (registry + system DLLs) — that upgrade and every
plugin write land on COW extents inside `prefix-copy/`. `WINEPREFIX` is how
Wine finds that clone; it is not the isolation boundary.

**The chain:**
```
generated .so at ~/.vst/yabridge (isolated tree overlaid on the host path)
  → finds yabridge-host.exe via PATH (our build/yabridge/ is first)
  → yabridge-host.exe wrapper reads $WINELOADER → wine 11.8
  → runs yabridge-host.exe.so with wine 11.8
  → loads Windows plugin DLL; WINEPREFIX is the production path, clone overlaid
```


## The sandbox boundary

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
| production Wine prefix (host) | **read-only** | never written, never upgraded. Inside the sandbox the clone is bound over this resolved path. A `~/winplugins` symlink stays a symlink and finds the overlay through that target |
| `~/.vst`, `~/.vst3`, `~/.clap` | **read-only** outside yabridge | production bridges cannot be modified, and are not on any plugin path. Isolated `~/.vst/yabridge`, `~/.vst3/yabridge` and `~/.clap/yabridge` are overlaid writable from `isolation/home` onto the resolved directory. The `~/.vst` symlink (if any) stays a symlink so Bitwig still sees `~/.vst/yabridge` |
| DAW install root, `--native-plugin-path` | read-only | the DAW's own files. A `bin` directory is widened to the install root beside it, but never inside your home — a DAW under `~/…/bin` gets that `bin` directory alone |
| `run-state/` | read-only | inside the project tree, so the DAW cannot rewrite the record of its own run |
| `prefix-copy/` | writable | the validated clone |
| `isolation/` | writable | the isolated HOME/XDG and bridge tree |
| `--writable-path DIR` | writable | your projects and rendered output. Paths under the login home are already visible because that home is bound as `HOME` |
| real login `$HOME` | **writable** | Bitwig settings, Wine known folders, and the rest of your user data. `HOME` is this path. Isolated `isolation/home/.BitwigStudio` is not `HOME` and must not win |
| `isolation/` XDG (`XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_CACHE_HOME`) | writable | yabridgectl and isolated bridges only. The DAW still uses `~/.BitwigStudio` under the real home |

The production Wine prefix is overlaid with the clone; the resolved
`~/.vst/yabridge`, `~/.vst3/yabridge` and `~/.clap/yabridge` directories are
overlaid with isolated bridges.
`--mac` keeps the login uid (and a files-only passwd whose home is the login
home) so Bitwig Java `user.home` is not `/root`. No D-Bus session socket is
exposed.

**Network:** the sandbox gets its own empty network namespace. Pass
`--network` to give the DAW the host network instead — for example for license
activation — and nothing else changes.

**XLN Computer ID / `--mac`:** Addictive Drums 2's "machine id" is the NIC MAC
Wine sees, not `/etc/machine-id` (already the host's via the read-only `/etc`
bind). Daily use runs `xln-fj` — Firejail `--net=$XLN_NIC --mac=$XLN_MAC`
(macvlan on the host NIC). That Firejail path is a **dead end** inside daw-env:
Firejail as a parent replaces `/usr/bin/bwrap` with `fbwrap`; Firejail
*inside* bwrap silently drops `--mac`; and unprivileged `nsenter` into
Firejail's netns fails (`EPERM`) because that netns lives in Firejail's
own user namespace. `--mac` therefore creates a **user+net namespace we
own**, starts `pasta --config-net --mac-addr <MAC>` (preferred) from the
host netns — attached with `--userns /proc/<pid>/ns/user --netns
/proc/<pid>/ns/net` so pasta still sees host routes — or `slirp4netns`
with that MAC, then runs real `/usr/bin/bwrap` inside that userns+netns.
bwrap must not `--unshare-net` or the MAC netns would be dropped. `--nic`
is the host template (`pasta --interface`); Wine always sees one NIC named
`eth0` (`pasta --ns-ifname eth0`), matching daily `xln-fj` / Firejail
(which is `eth0` or `eth0-<pid>`). `--address ADDR` pins the guest IPv4
(`pasta --address`); without it pasta copies the host template (NAT
a different LAN IP on 2026-08-28). That is still userspace NAT, not Firejail
macvlan L2 on the host NIC. Re-check `xln-fj`'s LAN IP before pinning — it
moved from one LAN address to another. Starting pasta inside
an empty `unshare --net` forces 169.254 local-mode. Passing
`xln-fj` as the first argument unwraps it into the same identity. Do not
wrap firejail as the sandboxed program. If pasta and slirp4netns are both
missing, the launcher names `passt` / `pasta` rather than dropping `--mac`.
`/etc/machine-id` already matches the host; Wine's `MachineGuid` is in
the clone. MAC + `eth0` were not enough for AD2 on 2026-08-28; the
clone-only XLN Online Installer plus Bitwig with the same `--address`
resolved **WRONG COMPUTER ID** on 2026-08-29 ~02:00. Pasta is still
NAT vs Firejail macvlan; that leftover difference was not a blocker
for this isolated run.

**Writable project paths:** `--writable-path DIR` is repeatable and strict.
`DIR` must be an existing directory given as a canonical absolute path: no
relative paths, no symlinks, no `.`/`..` components, no `:` or newlines, and no
option-looking values. It is rejected when it equals, contains, or sits inside
the production prefix, a production plugin root, a system root, the project
tree, the clone or the isolation tree — under either its own name or the
canonical name of a symlinked plugin root. The DAW's `HOME` is your real
login home, so `$HOME/.BitwigStudio` and Wine known folders are already
visible. You can still name a project directory with `--writable-path` if
it lives outside that home. The production Wine prefix is not auto-bound
writable. The real home **is writable** — that is the point (license,
settings, XLN content) and also the caveat. Isolated plugins that follow
Wine user-folder redirects then write into those real host directories.
Writes to the prefix land on `prefix-copy/`, not the production prefix.
Outside those writable mounts the DAW either fails to write or writes
into the private tmpfs that disappears with the run, so save projects and
renders into a path you approved. Isolated Bitwig will write settings and
license state back to the real `~/.BitwigStudio`.

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
| `Error: pasta and slirp4netns were not found in PATH` | `--mac` needs pasta (Arch: `pacman -S passt`) or slirp4netns. The launcher will not drop `--mac` and will not use Firejail+nsenter |

All of these happen *before* the prefix is cloned, before `yabridgectl` runs
and before the DAW starts.

## The run manifest

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

- the source inode and canonical path come from the clone's own provenance
  record and must still name that filesystem object. A remount that only
  changes the kernel device number is the same source; the recorded device is
  refreshed and published as the current `st_dev`;
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

## Wine diagnostics

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
  filesystem for a reflink clone. Without that, the script aborts rather
  than doing a full multi-GB copy. Pass `--copy` to opt in: it warns with
  the estimated size in GB, then copies.

## Advanced: manual env (use with care)

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

When using `./daw-env.sh reaper` (clone overlaid at the production prefix path):
```
generated .so at ~/.vst/yabridge (isolated tree overlaid on the host path)
  → finds yabridge-host.exe on PATH (our build/yabridge/ is first)
  → yabridge-host.exe wrapper reads $WINELOADER (our build/wine/bin/wine)
  → runs yabridge-host.exe.so with wine 11.8
  → loads Windows plugin DLL; WINEPREFIX is the production path, clone overlaid
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
production prefix stays read-only on the host; writes go to `prefix-copy/`
and to the real login home (`~/.BitwigStudio`, `~/Documents`, …).
