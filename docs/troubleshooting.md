# Troubleshooting

## yabridge-host.exe not found

Ensure `build/yabridge/yabridge-host.exe` exists after setup. If not, rerun
`./setup.sh --no-wine` to rebuild just yabridge.

## WINEPREFIX not initialized

```bash
source env.sh && yabridge-wine winecfg
```

Close winecfg when done. The prefix is now ready.

## Build fails

- You need `winegcc` (from system `wine` package) — this is the cross-compiler
  for the Windows host component.
- GCC >= 10 required.
- If `meson` can't find dependencies, install the -dev packages for your distro.

## bubblewrap cannot create the namespaces this launcher requires

`daw-env.sh` prints the exact probe it ran and what `bwrap` replied. The probe
only executes `/usr/bin/true` — no prefix and no plugin is involved. Either
enable unprivileged user namespaces:

```bash
sudo sysctl -w kernel.unprivileged_userns_clone=1   # persist in /etc/sysctl.d
```

or install a setuid `bwrap` (`bubblewrap-suid` on some distros). The launcher
retries without a user namespace automatically, so a setuid `bwrap` works
without any flag. It will not launch your DAW unsandboxed.

## A home-installed DAW cannot find its own libraries

Outside your home, a DAW at `/opt/Studio/bin/studio` gets all of
`/opt/Studio`, so its sibling `lib/` comes with it. Inside your home nothing is
widened — `~/opt/Studio/bin/studio` gets only `~/opt/Studio/bin` — because the
parent of a `bin` directory in your home is usually a directory like
`~/.local` that holds far more than the DAW. Install such a DAW outside your
home (`/opt` is already read-only in full) rather than loosening the boundary.

## The DAW cannot save a project

Only `prefix-copy/`, `isolation/`, your real login home, and each
`--writable-path DIR` are writable. Pass a project directory outside
`$HOME` explicitly:

```bash
./daw-env.sh --writable-path "$(realpath ~/Music/projects)" reaper
```

The path must be canonical (`realpath` output), must exist, and must not
overlap the production prefix, the production plugin roots, a system root, or
this project tree. Paths under your login home are already visible because
that home is `HOME`.

## Bitwig asks to accept the license or log in again

The DAW's `HOME` is your real login home. Bitwig stores its license, login
and settings in `~/.BitwigStudio` and must log that host path — not
`isolation/home/.BitwigStudio` and not `/root/.BitwigStudio`. `--mac` keeps
your login uid so Java `user.home` matches. Isolated XDG is only for
yabridgectl. Wine plugins resolve `SHGetKnownFolderPath` through
`C:\users\<name>\Documents` into `~/Documents` on that same real home.
You do not need an extra `--writable-path` for `.BitwigStudio` or
`Documents`. The production Wine prefix stays read-only on the host; prefix
writes land on `prefix-copy/`.

## The DAW has no sound or no window

`/dev/snd`, `/dev/dri` and the display/audio sockets are bound only when they
exist on the host. Check `DISPLAY`, `WAYLAND_DISPLAY`, `XAUTHORITY` and
`XDG_RUNTIME_DIR` are set in the shell you launch from — the sandbox binds the
specific socket those variables name, and nothing else.

## The launcher refuses because it cannot record the run

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

## Wine output is too noisy, or too quiet

Wine's diagnostics are no longer suppressed for you. Pass `--quiet-wine` for a
silent run, or set `WINEDEBUG` yourself (`WINEDEBUG=+relay ./daw-env.sh reaper`)
— see [Wine diagnostics](daw-sandbox.md#wine-diagnostics). Check
`run-state/run-manifest.json` if you want to know which of the two the last run
actually used.

## License activation fails

The sandbox has no network by default. Run the activation once with
`./daw-env.sh --network <daw>`.

## Wine prints winebrowser / urlmon.dll.CreateUri / native iertutil errors

Harmless leftover from the cloned production prefix. Wine 11.8 still has
native `iertutil` and related URL helpers registered; plugins or the XLN
installer may poke `winebrowser`. Close the dialogs. This is not an
isolation bug and does not mean the production prefix was written.

## XLN Online Installer / AD2 "machine id wrong"

The full procedure, every dialog we hit, and why **two restarts** are
success: [Isolated XLN Online Installer](xln-isolated-installer.md).

Short version: run the **updateBinary** path through daw-env (same
`--mac` / `--nic` / `--address` as Bitwig). daw-env pins `cacert.pem`,
syncs clone Program Files to 4.7.3, prefers that exe, and waits on
`wineserver` so Cotton's self-replace can come back. Do not `--fresh`.
Do not click Ignore. Production prefix stays read-only.

AD2 **WRONG COMPUTER ID** is the Wine Computer ID (MAC / NIC), not
`/etc/machine-id`. Pasta `--mac` is NAT + `eth0` + pinned IPv4, not
Firejail macvlan. Verified 2026-08-29 ~02:00: AD2 authorized in Bitwig
on the same clone and pasta identity after clone-only installer
authorize. Do not `--fresh`. If it returns, relaunch Bitwig with the
same `--mac` / `--nic` / `--address`.

```bash
./daw-env.sh --mac "$XLN_MAC" --nic "$XLN_NIC" --address "$XLN_ADDR" \
  --writable-path "$(realpath -- "$BITWIG_PROJECTS")" \
  "$PWD/build/wine/bin/wine" \
  "C:\\ProgramData\\XLN Audio\\Temp\\App\\Cotton XLN Online Installer\\updateBinary\\XLN Online Installer.exe"
```

## XLN installer window flashes and dies (`X_ShmPutImage`)

Wine on a Wayland session still uses XWayland. MIT-SHM (`X_ShmPutImage`
BadValue) needs the host IPC namespace and host `/dev/shm`. The sandbox
shares those (no `--unshare-ipc`). Retry the installer through daw-env.

## Wayland + xdotool

Mouse coordinate tests (`yabridge-test probe`; `validate` is a secondary
pointer) may not work under pure Wayland because `xdotool` depends on XTest.
Run under X11 or XWayland.

## Portability

`setup.sh` auto-installs deps only on pacman-based distros (Arch, Garuda,
Manjaro). On apt/dnf distros it prints a reminder — install the equivalents
manually.
