# yabridge-testing

Test **any yabridge build** — git master, a branch, a commit, a patched fork —
against a **Wine release you name and verify by digest**, without touching the
yabridge, Wine, prefixes, or plugins you use every day. Report what you find
to <https://yabridge-tests.fly.dev>; nothing is published until you read the
report and click Publish yourself.

yabridge 5.1.1 stable stops at Wine 9.21. The fixes for Wine 10+ live in git
and in proposed patches, and trying them normally means replacing the stack
you work with. This repository builds the stack under test in a directory of
its own, runs your real DAW against a throwaway copy of your real prefix, and
records exactly what ran.

## What it never touches

| | |
|---|---|
| **Your Wine and yabridge** | Everything is built into `build/` inside this checkout. Nothing is installed system-wide, and `setup.sh` never asks for `sudo`. |
| **Your production Wine prefix** | Mounted **read-only** inside the sandbox. The DAW sees a copy-on-write clone (`prefix-copy/`) bound over the same path; every write, including Wine's own prefix upgrade, lands on the clone. |
| **Your plugin bridges** | `~/.vst`, `~/.vst3`, `~/.clap` are read-only. Bridges for the test build are generated into `isolation/` and overlaid only on the `yabridge/` subdirectories. |
| **Unverified downloads** | Wine is fetched only after you name the release **and** its SHA-256. A mismatch installs nothing. There is no default version and no way to have the tool pick the digest for you. |
| **Your privacy** | Reports are sanitised before they leave the machine: no home paths, prefix paths, plugin paths, MAC addresses, e-mail, or license identifiers. `--dry-run` shows the exact payload. |
| **Your say** | A submit creates a **private draft** and prints a secret edit link. Save as often as you like; the report is public only after you click Publish. |

The sandbox is Bubblewrap, not a VM; the full mount table and its limits are in
[docs/daw-sandbox.md](docs/daw-sandbox.md) and [Residual risks](#residual-risks).

## Setup

```bash
git clone https://github.com/derEremit/yabridge-testing
cd yabridge-testing
```

Pick a Wine release at <https://github.com/Kron4ek/Wine-Builds/releases>
(archive `wine-<version>-staging-amd64.tar.xz`) and obtain its SHA-256 from a
source you trust — the release page, a signed checksum file, a copy you already
verified elsewhere. Do not take it from the download you are about to run.

```bash
./setup.sh --wine-version 11.16 --wine-sha256 <64-character-sha256>
# or keep using your system Wine and only build yabridge:
./setup.sh --no-wine
```

Setup installs build dependencies (pacman-based distros; others get a list),
downloads and verifies Wine into `build/wine/`, clones and builds the
yabridge ref you asked for (master by default) into `build/yabridge/`, creates `test-harness/.venv`, generates
`env.sh` / `test.sh`, and initialises an empty prefix at `prefix/`. Success is
recorded as `WINE_SHA256_VERIFIED=true` in `build/component-state.env`; a
launch requires that record and re-verifies rather than trusting a bare hash.

```bash
./setup.sh --no-wine                                       # rebuild yabridge from latest master
./setup.sh --no-yabridge --wine-version 11.17 --wine-sha256 <digest>   # move Wine
./setup.sh --yabridge-branch <ref> --no-wine               # a branch, tag, commit, or PR head to test
```

Requirements: `gcc >= 10`, `meson`, `ninja`, `wine` + `winegcc`, `libxcb`;
for the DAW sandbox `bubblewrap` 0.11+ with user namespaces (or a setuid
`bwrap`); for `--mac`, `pasta` (package `passt`) or `slirp4netns`. System
packages per distro: [docs/getting-started.md](docs/getting-started.md).

## Run the checks (no DAW involved)

```bash
./test.sh info                       # what Wine / yabridge the harness sees
./test.sh probe --scenario offset --samples 3 --json
./test.sh validate                   # pointer prerequisite + bridged coordinate matrix
./test.sh suite                      # everything
./test.sh plugin /path/to/plugin.vst3
```

The coordinate probe is a deterministic Windows CLAP fixture run first under
plain Wine, then through yabridge, in temporary prefixes and a headless X
server; an existing display is touched only with `--no-headless
--allow-pointer-warp`. Missing prerequisites are `SKIP`, harness faults are
`ERROR`, real mismatches are `FAIL`, and anything but a clean pass exits
non-zero. Build the pinned probe artifacts first — see
[docs/coord-probe.md](docs/coord-probe.md).

## Launch a DAW against a clone of your real prefix

```bash
./daw-env.sh reaper
./daw-env.sh bitwig-studio
./daw-env.sh --writable-path "$(realpath ~/Music/projects)" reaper
./daw-env.sh --network bitwig-studio          # host network, e.g. for a license check
./daw-env.sh --fresh reaper                   # start from a new clone
./daw-env.sh --clean                          # delete the clone
```

What happens, in order: the DAW and `bwrap` are resolved and the namespaces
probed; your prefix (default `~/.audio-production/winplugins`, or `--prefix`)
is reflink-cloned to `prefix-copy/` — instant and copy-on-write on btrfs/XFS,
`--copy` to opt into a full copy elsewhere; bridges for the test build are
generated into `isolation/`; the sandbox argv is built with the clone bound
over the production prefix path so the DAW keeps every plugin path it already
indexed; the run is recorded in `run-state/run-manifest.json`; then the DAW
starts. If any step cannot be proven, the DAW does not start — the launcher
never falls back to an unsandboxed run.

Your login `$HOME` is the DAW's `HOME` and stays writable, so DAW settings and
licenses behave normally. Plugins that need a specific network identity
(e.g. XLN's Computer ID) get one with `--mac` / `--nic` / `--address`; the
walkthrough that authorised a real license on the clone is in
[docs/xln-isolated-installer.md](docs/xln-isolated-installer.md).

Full reference — every flag, the mount table, `--mac` internals, the run
manifest, Wine diagnostics: [docs/daw-sandbox.md](docs/daw-sandbox.md).

## Report what you found

```bash
./test.sh probe --submit             # automated checks, then a draft
./test.sh suite --submit
./test.sh submit --session           # describe an isolated DAW session
./test.sh submit --session --dry-run # print the sanitised payload, send nothing
```

Every submit path POSTs a sanitised draft to `https://yabridge-tests.fly.dev`
and prints a secret edit URL. Open it, add notes, plugins and a verdict,
**Save** as often as you like, and **Publish** when it is right; only then does
the report appear on the site. What is and is not sent is specified in
[docs/harness-site-data.md](docs/harness-site-data.md). Nothing in this
repository submits on its own, and public CI never submits.

## Layout

```
setup.sh          build yabridge + verified Wine into build/
test.sh           run the harness CLI with the isolated environment
daw-env.sh        launch a DAW against a clone of your prefix, sandboxed
env.sh            generated by setup.sh (gitignored)
build/            wine/, yabridge/, yabridge-src/, component-state.env
prefix/           empty isolated WINEPREFIX for the harness
prefix-copy/      clone of your real prefix (created by daw-env.sh)
isolation/        isolated HOME/XDG and generated bridges
run-state/        run-manifest.json and operator-local state (gitignored)
test-harness/     Python CLI: probes, environment collection, submit
probe/            coordinate probe fixture (native + MinGW)
tests/            bats suites for every shell component
packer/ ansible/  VM images and provisioning for reproducible test hosts
docs/             everything below
```

## Documentation

- [docs/getting-started.md](docs/getting-started.md) — dependencies per distro, harness install, first run, VM images
- [docs/daw-sandbox.md](docs/daw-sandbox.md) — the DAW launcher in full: mounts, network identity, run manifest, diagnostics
- [docs/coord-probe.md](docs/coord-probe.md) — the coordinate probe: build, scenarios, measurements
- [docs/test-protocol.md](docs/test-protocol.md) — what a test session covers and how results are classified
- [docs/harness-site-data.md](docs/harness-site-data.md) — the harness ↔ results-site contract; what is never shared
- [docs/xln-isolated-installer.md](docs/xln-isolated-installer.md) — authorising an XLN product on the clone, step by step
- [docs/files-reference.md](docs/files-reference.md) — `setup.sh`, `env.sh`, `test.sh`, `daw-env.sh` flags and guarantees
- [docs/troubleshooting.md](docs/troubleshooting.md) — refusals, missing sound or window, license and installer problems

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
and the harness pytest suite when that venv exists. The same four workflows
run on GitHub for every push to `master`.

## Related

- [yabridge](https://github.com/robbert-vdh/yabridge) — the plugin bridge
- [Kron4ek Wine-Builds](https://github.com/Kron4ek/Wine-Builds) — prebuilt wine
  binaries
- [Issue #409](https://github.com/robbert-vdh/yabridge/issues/409) — Wine 10
  embedding discussion