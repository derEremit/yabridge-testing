# Provisioning and reproducibility design

Date: 2026-08-27

This is Phase 5 of
[`2026-08-25-yabridge-staging-remediation-design.md`](2026-08-25-yabridge-staging-remediation-design.md).
It covers the Phase 5 items this conversation scoped. It does not redo
Phases 1–4.

## Goal

Make the test-infra VM path bootable, build yabridge the way upstream does,
and stop publishing images that still contain the Packer login and
passwordless sudo. Pin the artifacts CI and installers actually fetch. Keep
the deployment story one QEMU/Packer tree plus Ansible playbooks; no new
orchestrator.

## Already done (do not redo)

- Parent isolation (Phase 1) and harness/probe CI (Phase 2)
- `web.yml` and results-server security (Phase 3)
- Alembic, grouped matrix, live health check (Phase 4)
- Ubuntu Packer ISO already has a SHA-256
- Probe CLAP wrap is already pinned

## Out of scope

- Python hash lockfiles and `pip-compile`
- Docker `python:3.11-slim@sha256:...`
- Wiring or completing unused `ansible/roles/yabridge` and `ansible/roles/wine`
- Filling missing role `include_tasks` that no playbook runs
- Kron4ek Wine tarball pins inside Ansible (parent `setup.sh` already owns
  digest-pinned Wine for local staging)
- Molecule, live SSH, or `packer build` on every PR
- WAL, `PRAGMA foreign_keys`, usage pruning, help-path/docs hygiene (Phase 6)

## Packer boot (NoCloud)

Ubuntu `boot_command` already requests
`ds='nocloud-net;s=http://{{ .HTTPIP }}:{{ .HTTPPort }}/'`. That datasource
requires `user-data` and `meta-data` at the HTTP root. Those files do not
exist. `packer/http/preseed.cfg` is a Debian-preseed name around an Ubuntu
autoinstall body and is not what NoCloud fetches.

- Add `packer/http/user-data`: the current autoinstall document (today's
  `preseed.cfg` body). It may still plant a build-time password hash and a
  `NOPASSWD` drop-in so Packer can SSH in.
- Add `packer/http/meta-data` with at least `instance-id: yabridge-ubuntu`.
- Delete `packer/http/preseed.cfg` so the HTTP root cannot serve the wrong
  name. Do not leave a second copy of the autoinstall payload.
- Leave the Ubuntu `boot_command` pointing at the HTTP root. Do not switch
  away from `nocloud-net`.
- Arch stays on `archinstall.json` and does not gain NoCloud files.

Tests: `packer validate` on both templates; a static test that `user-data`
and `meta-data` exist, that `user-data` starts with `#cloud-config`, and that
`preseed.cfg` is gone.

## Publish-time secrets

Packer may use `ssh_password` (and the autoinstall hash / Arch `chpasswd`)
**during** the build. The published artifact must not.

The last provisioner on **both** templates is one root script that, in this
order:

1. Locks the image user password (`passwd -l` or equivalent).
2. Removes `/etc/sudoers.d/yabridge` (Ubuntu) and any `%wheel NOPASSWD: ALL`
   / `NOPASSWD:ALL` line this tree added (Arch).
3. Powers off the guest (`shutdown -P now`).

Do that in one `sudo bash -c '...'` while passwordless sudo still exists.
After step 2, `echo "$password" | sudo -S shutdown` no longer works, so
Packer's `shutdown_command` must not be the only power-off path. Set
`shutdown_command` to a no-op that tolerates an already-dead SSH session
(for example `true`), and let the last provisioner be the shutdown.

Do not leave the known default password (`yabridge` / the live-ISO root
password) usable on the published disk. Packer variable defaults may still
exist in the template for the *build* SSH; they are not an account on the
finished image.

Tests: a static check that both `.pkr.hcl` files contain `passwd -l` (or
`usermod -L`) and remove the sudoers drop-in / wheel NOPASSWD in the last
provisioner, and that `shutdown_command` is not `sudo -S shutdown` after
that strip. Do not require a full `packer build` on PR.

## Ansible / Meson

`ansible/playbooks/build-yabridge.yml` is the documented build. It still
runs CMake. Upstream yabridge in this project is Meson-only
(`meson setup build --cross-file=cross-wine.conf`).

- Rewrite that playbook in place. Configure with
  `meson setup build --buildtype=release --cross-file=cross-wine.conf`
  from the clone root (not from a nested `build/` with `cmake ..`).
- Build with `meson compile -C build`. Install with `meson install -C build`
  using the same prefix the playbook already uses (`/opt/yabridge` by
  default).
- Do **not** pass `-Dbitbridge=true` unless the cloned tree's
  `meson_options.txt` defines `bitbridge`. The current upstream options file
  does not.
- Debian deps: keep `wine64-tools` and MinGW; add `meson` and `ninja-build`;
  drop CMake as a *build* command. Leave the `cmake` package only if a wrap
  still needs the binary (upstream `cross-wine.conf` mentions it).
- Arch deps: add `meson` and `ninja`; same CMake rule.
- Delete the `include_vars` of `{{ distro | default('ubuntu') }}.yml` from
  `provision-base.yml`. Those files do not exist, the playbook ignores the
  failure, and no later task reads those vars. Do not add placeholder yml
  files.
- Do not `import_role` `roles/yabridge` or `roles/wine`. Do not create their
  missing `include_tasks` files.
- `docs/getting-started.md` still runs `playbooks/build-yabridge.yml` and
  must describe Meson + `cross-wine.conf`, not CMake.

Tests: `ansible-playbook --syntax-check` on the five playbooks getting-started
names. A contract test that `build-yabridge.yml` contains
`--cross-file=cross-wine.conf` and `meson setup`, and does not contain
`cmake ..`.

## Pins

Pin what this phase named. Record the exact version and checksum in the
file that fetches the bytes.

| Asset | Action |
|---|---|
| Arch ISO | Replace `iso/latest` with a dated ISO URL. Set `iso_checksum` to `sha256:<digest>`. Do not leave `"none"`. |
| Ubuntu ISO | Already has a SHA-256. Leave it unless the URL is moved. |
| Packer qemu plugin | Exact version in both `.pkr.hcl` files, not `>= 1.1.0`. |
| Packer CLI | `hashicorp/setup-packer` gets a commit SHA and an exact Packer version, not `@main` + `latest`. |
| GitHub Actions | `actions/checkout`, `actions/setup-python`, `actions/upload-artifact`, and `hashicorp/setup-packer` become `name@<40-char-sha>` with a comment naming the tag that SHA is. Apply to every workflow this repo already has (`web.yml`, `test-harness.yml`, `probe.yml`, `build-images.yml`, and the new Ansible workflow). |
| Plugin/DAW `get_url` | Keep the versioned URLs already in `install-test-plugins.yml` and `install-daws.yml` (Vital v1.5.5, Dexed v0.9.7, OB-Xd v2.10, REAPER 7.24). Add `checksum: sha256:<digest>` only when that vendor publishes a checksum file or signed digest for that exact URL. Do not hash a file you just downloaded and call it a pin. If no official digest exists, leave the versioned URL and name the gap in `docs/getting-started.md`. The unused `roles/test-plugins` copy is out of scope. |

Wine **packages** stay channel packages (`winehq-stable` / distro `wine`).

## CI

- Add `.github/workflows/ansible.yml` on `ansible/**` and that workflow file:
  `ansible-playbook --syntax-check` for the five documented playbooks.
  No Molecule. No live hosts.
- Keep `build-images.yml` `packer validate` on PR/push. Full `packer build`
  stays `workflow_dispatch` only.
- Do not rewrite `web.yml` or `test-harness.yml` except to pin action SHAs.
- Parent repo still has no `.github/`. Do not add one.

## Repository boundary

All Packer, Ansible, and workflow changes land in `yabridge-test-infra`
first. The parent repository only records the new submodule gitlink.
Nothing is pushed unless asked.

## Success criteria

- Ubuntu Packer `validate` succeeds with NoCloud `user-data` and `meta-data`
  present and `preseed.cfg` gone.
- A published-image provisioner locks the user password and removes
  passwordless sudo, then powers off. Packer does not need the old password
  to shut down.
- `build-yabridge.yml` is Meson + `cross-wine.conf`. Getting-started matches.
- `provision-base.yml` does not include missing var files.
- Arch ISO, Packer, and Actions have immutable versions and checksums.
  Installer `get_url`s stay versioned; official vendor digests are attached
  when they exist.
- Ansible syntax CI exists. Packer validate still runs on `packer/**`.
- No Python lockfile, no Docker digest, no unused-role resurrection.
