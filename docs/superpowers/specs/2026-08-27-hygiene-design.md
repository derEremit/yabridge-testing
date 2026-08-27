# Hygiene and documentation design

Date: 2026-08-27

This is Phase 6 of
[`2026-08-25-yabridge-staging-remediation-design.md`](2026-08-25-yabridge-staging-remediation-design.md).
It covers the Phase 6 items this conversation scoped. It does not redo
Phases 1–5.

## Goal

Make the documented commands and safety claims match what the trees actually
do. Help must work without a configured prefix. A local check recipe must
name the suites that already exist. Residual risk and the three-way repo
boundary must be explicit.

## Already done (do not redo)

- `setup.sh` and `daw-env.sh` `--help` (exit 0) and missing-option validation
  (exit 2) — Phase 1 bats in `tests/setup_cli.bats` / `tests/run_manifest.bats`
- Web `ruff` / `mypy` / `pytest` in `web.yml` — Phases 3–4
- Harness pytest in `test-harness.yml` — Phase 2
- Meson wording and installer-digest residual sentence in
  `yabridge-test-infra/docs/getting-started.md` — Phase 5
- Parent has no `.github/` — keep it that way

## Out of scope

- Python hash lockfiles and Docker image digests (Phase 5 ruling)
- Parent GitHub Actions or a parent remote
- Unused Ansible roles, Molecule, WAL / FK pragma / pruning
- Rewriting `architecture.md` or the results-server security chapter
- Pushing either repository

## Help paths

`./test.sh --help` and `./test.sh -h` must exit 0 **without** `env.sh` or the
harness venv. Today `test.sh` sources `env.sh` first, so help fails on a
fresh clone.

- Handle `-h` / `--help` before any environment check.
- Print a short usage that names `info`, `probe`, and `suite`, then exit 0.
- Keep the rest of the wrapper aligned with what `setup.sh` already
  generates: require `env.sh` and
  `yabridge-test-infra/test-harness/.venv/bin/yabridge-test`; exec that
  binary; never fall back to a global `yabridge-test`.
- `setup.sh` must write the same `test.sh` body (the heredoc already
  overwrites it).

Add a bats test that `./daw-env.sh --help` exits 0. The implementation
exists; the dedicated assertion does not.

Do not invent new flags. Click `--help` on the harness stays as Click
provides it.

## Documentation

### Clone URL

Three files still clone `github.com/robbert-vdh/yabridge-test-infra`. That
repository does not host this project. Replace every occurrence with
`https://github.com/derEremit/yabridge-test-infra` (the submodule `origin`):

- `yabridge-test-infra/README.md`
- `yabridge-test-infra/docs/contributing.md`
- `yabridge-test-infra/install.sh` (`REPO_URL`)

Do not change links to `robbert-vdh/yabridge` itself.

### Commands

Lead measured mouse/coordinate work with `probe`, not `validate`.

- `setup.sh` generated `env.sh` footer: replace
  `yabridge-test validate — run mouse coordinate tests` with a `probe` line.
- `setup.sh` completion banner: `./test.sh validate` becomes
  `./test.sh probe`.
- Parent README Wayland troubleshooting: mention `probe` (keep `validate`
  only if it is still a real command, as a secondary pointer).

### Safety claims

`WINEPREFIX` is not the isolation boundary. Phase 1 is: prefix clone,
clone-only bridges, Bubblewrap read-only mounts of production paths.

Rewrite these two parent README passages so they do not say the original
prefix is “physically never touched” because of `find_wine_prefix()` /
`WINEPREFIX` alone:

- “Why this is safe” under the DAW launcher
- The `daw-env.sh` tool description (“original prefix is physically never
  modified”)

State what is actually enforced: the launcher refuses to start without
`bwrap`; production prefix and plugin roots are mounted read-only; bridges
used for the run resolve inside the clone. Residual escape (kernel userns
policy, a path not in the mount table, a plugin talking to something
outside the sandbox) belongs in Residual risks, not in the safety blurb.

The setup completion line “originals never touched” gets the same treatment
(one honest clause, not a guarantee).

### Residual risks and boundary

Add a **Residual risks** section to the parent README. Keep it short. It
must name:

- Isolation is a Bubblewrap sandbox, not a VM. Paths that are not in the
  mount table are not protected by it.
- Plugin/DAW installer URLs in Ansible are version-pinned only; vendors
  published no digests (Phase 5).
- Packer templates still contain a build-time password hash / SSH password
  so the image can be provisioned; the last provisioner locks those
  accounts before the published disk is written.
- No Python lockfiles and no Docker image digest.
- This parent repository is local orchestration (`setup.sh`, `daw-env.sh`).
  `yabridge-test-infra` is the publishable harness / web / Packer repo.
  Upstream `robbert-vdh/yabridge` is never modified here
  (`build/yabridge-src` is an untracked clone).

## Local check recipe

Parent still has no CI. Add `scripts/check.sh` that runs, in order, and
fails on the first nonzero:

1. `shellcheck` on parent `setup.sh`, `daw-env.sh`, `test.sh`,
   `scripts/check.sh`, and `lib/*.sh`
2. `bats tests`
3. If `yabridge-test-infra/web/.venv/bin/python` exists: `pytest -q`,
   `mypy app`, `ruff check app tests` from `web/`
4. If `yabridge-test-infra/test-harness/.venv/bin/python` exists: the same
   harness pytest marker set `test-harness.yml` uses
   (`not native_probe and not wine_probe and not live_probe`)

If a venv is missing, print a one-line skip for that block; do not fail
the script for a missing optional suite. `shellcheck` and `bats` are
required.

Document the script under a **Checks** heading in the parent README
(one paragraph + `./scripts/check.sh`).

Fix any `shellcheck` findings this recipe surfaces on the listed files.
Do not add `# shellcheck disable` wholesale to silence them.

## Repository boundary

URL and `install.sh` changes land in `yabridge-test-infra` first. Parent
owns README, `test.sh`, `setup.sh` banner/footer, bats, and
`scripts/check.sh`. The parent gitlink updates after the submodule merge.
Nothing is pushed unless asked.

## Success criteria

- `./test.sh --help` and `./daw-env.sh --help` exit 0 without `env.sh`.
- No file in either tree clones `robbert-vdh/yabridge-test-infra`.
- Parent README does not claim the original prefix is physically never
  touched. Residual risks and the repo boundary are written down.
- Documented mouse/coordinate examples lead with `probe`.
- `./scripts/check.sh` is the named local gate and is green on this
  machine when the required tools are installed.
