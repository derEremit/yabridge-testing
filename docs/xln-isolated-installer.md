# Isolated XLN Online Installer (clone-only)

How to run XLN Audio's Cotton **XLN Online Installer** through `daw-env.sh`
so every write lands on `prefix-copy/` (overlaid at the production prefix
path). The production Wine prefix stays **read-only on the host**.

This is the procedure that, on **2026-08-29 ~01:54**, reached
**Installation Finished / Everything is up to date** after **two in-app
restarts** inside one sandbox. Do not start the next session from zero.
Do not `--fresh` or `rm -rf prefix-copy`.

See also: [DAW sandbox reference — command forms](daw-sandbox.md#command-forms).

## Outcome (2026-08-29)

| | |
|---|---|
| Account | the operator XLN account (`XLN_ACCOUNT` in `run-state/identity.env`) (logged in inside the installer) |
| Installer | Cotton **4.7.3** (`4_7_3 Release1 2026-08-18 - 14-26-25`) |
| BinaryLocation | `C:\Program Files\XLN Audio\XLN Online Installer\` |
| ComputerId | derived value, not the raw MAC (recorded in gitignored `run-state/`) |
| Host Wine | `wine-11.16 (Staging)` from `build/wine/` |
| Prefix | clone `prefix-copy/` overlaid on `~/.audio-production/winplugins` |
| Network | pasta `--mac "$XLN_MAC" --nic "$XLN_NIC" --address "$XLN_ADDR"` |
| Restarts | **two** (updater self-replaced, then came back). Expected. |
| UI | Product list with green checks; dialog **Installation Finished** / **Everything is up to date** |

Logs: `~/Documents/XLN Online Installer Logs/` (Wine known folder is the
real login `Documents`). Cotton often only flushes a 54-line boot dump
(`Exception: Invalid data format` there is **normal**, including on daily
`xln-fj` runs). Trust the UI, not the short log.

**Verified in Bitwig (2026-08-29 ~02:00):** Addictive Drums 2
**authorized** on the same clone and pasta identity
(`--mac "$XLN_MAC" --nic "$XLN_NIC" --address "$XLN_ADDR"`). Pasta
is still userspace NAT, not Firejail macvlan L2. That was enough after
clone-only installer authorize. Do not `--fresh`.

## Command that worked

Pass the **updateBinary** Windows path. daw-env rewrites it. Do not launch
the Program Files exe yourself; do not launch `xln-fj` as the daw-env
binary if you want the clone-only write set.

```bash
./daw-env.sh --mac "$XLN_MAC" --nic "$XLN_NIC" --address "$XLN_ADDR" \
  --writable-path "$(realpath -- "$BITWIG_PROJECTS")" \
  "$PWD/build/wine/bin/wine" \
  "C:\\ProgramData\\XLN Audio\\Temp\\App\\Cotton XLN Online Installer\\updateBinary\\XLN Online Installer.exe"
```

Reuse the clone (omit `--fresh`). If bridges are already generated, omit
`--refresh-bridges`.

After the installer stays on **Everything is up to date**, Bitwig:

```bash
./daw-env.sh --refresh-bridges --mac "$XLN_MAC" --nic "$XLN_NIC" \
  --address "$XLN_ADDR" \
  --writable-path "$(realpath -- "$BITWIG_PROJECTS")" \
  bitwig-studio
```

## What you must not do

| Don't | Why |
|---|---|
| `--fresh` / `rm -rf prefix-copy` | Drops clone license/device state and the synced 4.7.3 Program Files tree |
| Click **Ignore** on Lua/disk-space dialogs | Stops the retry loop and leaves “Checking installation” forever |
| Treat **OK** on “Wrong resources” as success | Version mismatch; quit and relaunch |
| Launch Program Files yourself | Wine `ReplaceFileW` is a stub; that exe was 4.7.2 until daw-env synced it |
| Nest Firejail + bwrap (`xln-fj` as parent, or Firejail inside bwrap) | `--mac` dropped or `fbwrap` argc cap; use daw-env `--mac` |
| Expect an automatic window after a self-update **without** `wine-wait.sh` | First `wine` process exits; bwrap tears down; child dies |
| Write the production prefix | Host bind is read-only; all installer state must stay on the clone |

Wine `fixme:` lines (DPI, DWM, bcrypt, wininet SameSite, `ReplaceFileW`
flags 6, `GetCurrentPackageId`) are noise. `urlmon.dll.CreateUri` /
native `iertutil` leftover dialogs: close them.

## How daw-env launches this installer

You still type the updateBinary path. The launcher then:

1. **Pin `cacert.pem`.** Restore the CA bundle onto the clone CAfile paths
   and `--ro-bind` `run-state/xln-cacert.pem` over those **files only**.
   Wine `ReplaceFileW` deletes `installData_app\cacert.pem` on every start;
   curl then fails with **error 77**. `chattr +i` is best-effort
   (`CAP_LINUX_IMMUTABLE` is often missing). The file bind is what holds.
2. **Repair / stage Cotton payload** on the clone only
   (`lib/sandbox.sh`: `sandbox_repair_xln_updatebinary_payload`,
   `sandbox_stage_xln_updatebinary_launch_copy`).
3. **Sync Program Files + installed App** from current `updateBinary`
   when hashes/versions differ (`sandbox_sync_xln_installed_from_updatebinary`).
   Destinations are realpath-checked to stay inside `prefix-copy/`.
   Production prefix is never read or written.
4. **Prefer Program Files** when that exe already matches `updateBinary`.
   Otherwise stage a sibling **`launchCopy/`** (full snapshot of
   `updateBinary` contents: exe + `installData/` + Certs/xpak) and run
   that, so `updateBinary\XLN Online Installer.exe` is not the mapped
   image (`remove_all` Access denied / 5).
5. **chdir** to the exe directory (`sandbox_launch_chdir`) so relative
   `Certs\cacert.pem` resolves. Lua resources come from
   **GetModuleFileName** (exe dir), not `$HOME`.
6. If the DAW is `wine` / `wine64`, wrap with
   [`lib/wine-wait.sh`](../lib/wine-wait.sh): run Wine, then
   `wineserver -w`. The run manifest allows only
   `-- lib/wine-wait.sh <recorded-wine> …` as a wrapper
   (`lib/run-manifest.sh`).

Network for `--mac`: `lib/mac-netns-exec.sh` — `unshare --user --map-root-user --net`,
pasta from the **host** with `--userns`/`--netns` after `uid_map` is ready,
guest iface **`eth0`**, `--mac-addr` / `--ns-mac-addr`, `--interface $XLN_NIC`,
DNS `1.1.1.1` and `192.168.1.1` (host Tailscale `100.100.100.100` is
unusable in pasta). `--address` pins guest IPv4. That is still **NAT**,
not Firejail macvlan.

Sandbox HOME is the real login home. `--uid`/`--gid` plus a files-only
passwd overlay keep Bitwig Java `user.home` off `/root`. Host IPC and
host `/dev/shm` (no `--unshare-ipc`) so XWayland MIT-SHM works.

## Why two restarts are success, not a loop

Cotton's updater is a bootstrapper:

1. A process shows login / “update XLN updater”.
2. It downloads or applies a payload (`ReplaceFileW` on Wine is a **stub**;
   Program Files would stay 4.7.2 without the clone sync).
3. It `ShellExecute`s the replacement exe and **exits**.
4. Without `wineserver -w`, bwrap's main command is that first `wine`
   process. When it exits, the namespace is torn down and the child dies
   — UI appears, then the session is gone. That is **not** a GPU crash.
5. With `wine-wait.sh`, wineserver keeps the sandbox until every Wine
   process in the prefix is gone. The replacement comes back. A second
   restart is the same handoff again.

The successful run did this **twice**, then showed the product list and
**Everything is up to date**. Leave the window up; click **Ok** on that
dialog. Then authorize / confirm AD2 if the list still asks, and only
then start Bitwig with the same MAC identity.

## Failure ladder (what we hit, in order)

Work down this table if a future run breaks. Each row is a **different**
dialog or log line. Do not click Ignore.

| Symptom | Actual cause | What daw-env does now |
|---|---|---|
| `ConnectionFailed: 77` … `cacert.pem` / `CApath: none` | Updater deletes the CAfile (`ReplaceFileW`); curl has no CA | Restore + **file-only** `--ro-bind` of `run-state/xln-cacert.pem` |
| Lua “disk space” + `remove_all` Access denied (5) on `updateBinary\…exe` | Running image is the file it tries to delete | Stage **launchCopy** (or run synced Program Files); leave updateBinary unlocked |
| `[lua main] Wrong resources` | Exe 4.7.3, resources still 4.7.2 or missing next to exe (GetModuleFileName) | Full payload snapshot into launchCopy; repair from Cotton bundle on the clone |
| Updates, quits, **no restart** | Installed App/Program Files still **4.7.2**; API sent `"4_7_2 Release1"` (404 `updateUserComputerVersions`); bootstrapper exits | Sync clone Program Files exe + `ProgramData\…\App\…\.version` / xpak from updateBinary |
| Login/update UI, then dies after `ReplaceFileW` | launchCopy/`wine` exits after ShellExecute; sandbox dies | Prefer Program Files once hashes match; **`wineserver -w`** |
| Manifest: `does not execute the recorded DAW: …/wine` | `--` was `wine-wait.sh`, check required `wine` | Allow only `*/lib/wine-wait.sh` then the recorded Wine |
| Window flashes, `X_ShmPutImage` BadValue | Private IPC/`/dev/shm` vs XWayland MIT-SHM | Share host IPC + bind host `/dev/shm` |
| Cannot download / bad DNS | pasta inherited Tailscale `100.100.100.100` | pasta `--dns 1.1.1.1 --dns 192.168.1.1 --dhcp-dns` |
| Firejail `--mac` dropped / `fbwrap` / `nsenter` EPERM | Must not nest Firejail and bwrap | pasta netns we own; unwrap `xln-fj` into `--mac`/`--nic` |
| Fail-fast `c0000409` ~20 s in, before any click; Cotton log `setFloat(Cotton_Stats_messageReceived_CallFreq_Avg) can't set parameter to inf` | Cross-core timestamp skew (seen on RT kernels; also `mDNSPlatformRawTime went backwards` lines) makes Cotton's stats math hit a zero/negative time delta | Pin the installer launch to one core: `taskset -c <core> ./daw-env.sh --mac … wine …`. DAW sessions do not need pinning (2026-08-31, reproduced 2/2, fixed 2/2) |

Clone identity: `lib/clone-state.sh` accepts the same path+inode if
`st_dev` changes (btrfs remount). Do not treat that as a reason to
`--fresh`.

## Paths (clone only)

All of these are under `prefix-copy/drive_c/` unless noted.

| Role | Path |
|---|---|
| Cotton download / updater payload | `ProgramData\XLN Audio\Temp\App\Cotton XLN Online Installer\updateBinary\` |
| Staged unlocked copy (when PF is not current) | `…\Cotton XLN Online Installer\launchCopy\` |
| Installed exe Wine cannot ReplaceFile | `Program Files\XLN Audio\XLN Online Installer\XLN Online Installer.exe` |
| Installed version string the WebAPI sent as 4.7.2 | `ProgramData\XLN Audio\XLN Online Installer\App\XLN Online Installer\XLN Online Installer.version` |
| Curl CAfile that gets deleted | `…\updateBinary\installData\installData_app\cacert.pem` |
| Host CA cache (project, gitignored) | `run-state/xln-cacert.pem` |
| License / device state | `ProgramData\XLN Audio\` and `users\z3n\AppData\Roaming\XLN Online Installer\` |
| Cotton logs | host `~/Documents/XLN Online Installer Logs/` |

Production `~/.audio-production/winplugins` Program Files exe stayed
**4.7.2** (`f941e281…`, 2026-05-14) on purpose. Only the clone was
synced to **4.7.3** (`eb72af22…`).

## Code map

| File | Role |
|---|---|
| `daw-env.sh` | Flags, rewrite last argv, pin/sync, set `SANDBOX_WINESERVER` |
| `lib/sandbox.sh` | Mounts, chdir, cacert binds, launchCopy, PF prefer, wine-wait wrap |
| `lib/wine-wait.sh` | `wine …; wineserver -w` |
| `lib/run-manifest.sh` | Fail-closed argv: DAW, or `lib/wine-wait.sh` + DAW |
| `lib/mac-netns-exec.sh` | pasta/slirp holder for `--mac` |
| `lib/clone-state.sh` | Clone source identity |
| `tests/sandbox.bats` | CAfile, launchCopy, PF prefer, wine-wait argv |
| `tests/run_manifest.bats` | wine-wait accepted; other wrappers refused |

## Isolation vs daily `xln-fj`

Daily `~/.local/bin/xln-fj` is Firejail `--net=$XLN_NIC --mac=$XLN_MAC`
(macvlan, iface `eth0-<pid>`, the LAN IP in `run-state/identity.env`). daw-env cannot join
that netns unprivileged and must not parent/child Firejail with bwrap.
`--mac` approximates identity (MAC + `eth0` + pinned IPv4 + DNS). L2 is
still pasta NAT. AD2 **WRONG COMPUTER ID** was resolved on this path
after clone-only installer authorize plus Bitwig with the same `--mac`
/ `--nic` / `--address` (2026-08-29 ~02:00). Pasta vs Firejail macvlan
L2 is still a leftover difference; it was not a blocker for this
isolated run.

## Relaunch later

Reuse this clone. Do **not** `--fresh`. Keep the same `--mac` / `--nic` /
`--address`. If bridges are already generated, omit `--refresh-bridges`.

Installer (pass the **updateBinary** path; daw-env rewrites it). Two
in-app restarts are success — `wine-wait.sh` keeps the sandbox up:

```bash
./daw-env.sh --mac "$XLN_MAC" --nic "$XLN_NIC" --address "$XLN_ADDR" \
  --writable-path "$(realpath -- "$BITWIG_PROJECTS")" \
  "$PWD/build/wine/bin/wine" \
  "C:\\ProgramData\\XLN Audio\\Temp\\App\\Cotton XLN Online Installer\\updateBinary\\XLN Online Installer.exe"
```

Bitwig after the installer stays on **Everything is up to date**:

```bash
./daw-env.sh --refresh-bridges --mac "$XLN_MAC" --nic "$XLN_NIC" \
  --address "$XLN_ADDR" \
  --writable-path "$(realpath -- "$BITWIG_PROJECTS")" \
  bitwig-studio
```

## Reporting a click regression

First click on a plugin UI that only focuses, then later clicks land
correctly, is the same report as [derEremit on yabridge
#409](https://github.com/robbert-vdh/yabridge/issues/409) — comment
there, do not open a new issue. Robbert asked to keep Wine 10+ embedding
reports on that thread.

Live identities from this tree (do not guess 11.8):

- yabridge master `b580a9f7fc46509767ca156d4f92872552b9e571` (`build/component-state.env`, `build/yabridge-src`)
- Wine `wine-11.16 (Staging)` Kron4ek (`run-state/run-manifest.json`)
- Host: Bitwig through `./daw-env.sh`, isolated `yabridgectl` on the clone prefix
- Session: Garuda Linux (CachyOS kernel), KDE Plasma Wayland, Wine on XWayland (`DISPLAY=:0`)
- AD2 / XLN auth works on this clone + pasta identity
- Last considered stable that did **not** need the extra first click: yabridge 5.1.1 + Wine 9.21

Fill in the plugin list yourself. Confirm after focus that clicks are
not the #409 coordinate offset.
