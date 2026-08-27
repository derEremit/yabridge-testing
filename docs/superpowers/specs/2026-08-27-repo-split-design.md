# Public test repo / private website design

Date: 2026-08-27

This replaces the historical submodule split. It is not a numbered
remediation phase. Phases 1–6 stay as they are; this re-cuts the trees
so visibility matches the product.

## Goal

One **public** repository someone clones to isolate Wine, build yabridge,
run the harness, and provision test VMs. One **private** repository that
is only the Fly results server. No submodule. The website source is not
in the public tree.

## Why the current split is wrong

`yabridge-test-infra` existed first (harness + VMs + website). Staging
was added as a local consumer and gitlinked that repo. That is two
lifetimes, not two audiences. Pushing today's submodule would publish
`web/`. Leaving staging unpublished means nobody else can run isolation.

## Target repositories

| Repo | Visibility | Role |
|---|---|---|
| `yabridge-staging` (this tree) | public | Isolation, harness, probe, Packer, Ansible, their tests and CI |
| `yabridge-results` (new, from `web/` only) | private | FastAPI app, Alembic, Dockerfile, `fly.toml`, web tests, web CI |

The public clone is:

```bash
git clone https://github.com/derEremit/yabridge-staging
cd yabridge-staging
./setup.sh --wine-version 11.8 --wine-sha256 <digest>
./test.sh probe
./daw-env.sh reaper
```

No `--recurse-submodules`. Harness lives at `test-harness/`.

The private clone is only for deploying the site. The public harness
keeps submitting to `https://yabridge-tests.fly.dev` (API URL, not
source). That default stays.

## Public tree layout (after the move)

In-tree, not under `yabridge-test-infra/`:

- `setup.sh`, `daw-env.sh`, `test.sh`, `lib/`, parent `tests/`
- `test-harness/`
- `probe/`
- `packer/`, `ansible/`
- `install.sh` (clones this public repo; tarball dir `yabridge-staging-main`)
- `LICENSE` (copy the submodule MIT notice; this tree has none today)
- infra docs that are not operator-only (`docs/coord-probe.md`,
  `docs/test-protocol.md`, `docs/getting-started.md` **without** the
  “Running the Results Server” / `cd web` chapter). Do not copy
  `architecture.md` unless website-operator chapters are stripped.
  Do not copy `contributing.md` unless its clone URL is rewritten;
  if you skip it, drop links to it from getting-started.
- `.github/workflows/`: `test-harness.yml`, `probe.yml`, `ansible.yml`,
  `build-images.yml` (same pins as today). These must land **before**
  `tests/test_ansible_build.py` is collected — that file reads
  `.github/workflows/ansible.yml`.
- `tests/test_packer_nocloud.py`, `tests/test_ansible_build.py` (paths
  updated)
- Parent `.gitignore` gains the submodule probe/packer ignore rules
  (`probe/build*/`, `probe/subprojects/clap/`, `probe/subprojects/packagecache/`)
  so a naive `git add probe` cannot stage Meson build trees.

Gone from the public tree:

- `.gitmodules` and the `yabridge-test-infra` gitlink
- `web/`
- `.github/workflows/web.yml`

`scripts/check.sh` runs shellcheck, parent bats, then optional
`test-harness/.venv` pytest. It does **not** look for a web venv.

## Private tree layout

A new git repository whose first commit is the current `web/` directory
as the repo root (today's `web/app` becomes `app/`, and so on). Copy
`LICENSE`. Copy `web.yml` to `.github/workflows/web.yml` and run jobs
at repo root (`web/**` path filters and `working-directory: web` go
away).

Rewrite tests that assume the combined tree:

- `tests/test_quality_config.py`: `ROOT` is the private repo root
  (`parents[1]`), `PYPROJECT` is `pyproject.toml`, workflow paths are
  not prefixed with `web/`, and there is no `working-directory: web`.
- Do **not** copy `tests/test_harness_contract.py`. It loads sibling
  `test-harness/src/yabridge_test/schemas.py`. The private tree must
  not contain that directory.
- `tests/test_operations_docs.py`: stop reading
  `../docs/architecture.md`. Assert operator settings against the
  copied `README.md` only.

The live installer the site serves (`INSTALL_SCRIPT` in `app/main.py`)
must clone `https://github.com/derEremit/yabridge-staging` and `cd`
into that clone's `test-harness/`. Keep it aligned with public
`install.sh`. Retarget or drop the footer Source link
(`github.com/yabridge/yabridge-test-infra` in `templates/base.html`).
Rename the `fly.toml` comment so it does not say `yabridge-test-infra`.

Do not `git filter-repo` the combined history into the public repo.
Copy current files. Public history then never contains `web/`.

The existing GitHub remote `derEremit/yabridge-test-infra` already has
`web/` on `origin/main`. That remote must be **private** (or archived)
before any “publish test stuff” step. Do not push the 66 local combined
commits to a public `yabridge-test-infra`. After `yabridge-results`
exists, that old remote is leftover; making it private is enough.

## Path and fixture updates

Every `yabridge-test-infra/test-harness` becomes `test-harness`.
`setup.sh` `HARNESS`, the `test.sh` heredoc, `scripts/check.sh`, and
**all** bats fixtures that copy the harness:

- `tests/setup_components.bats`
- `tests/setup_fixture.bash`
- `tests/setup_harness.bats`

The fixture directory name `yabridge-test-infra` dies; copy into
`$FIXTURE/test-harness` / `$FIXTURE_ROOT/test-harness`.
`./scripts/check.sh` is `bats tests` and will load those files.

`install.sh` and clone-URL tests point at
`https://github.com/derEremit/yabridge-staging`, not
`derEremit/yabridge-test-infra`. The tarball fallback directory is
`yabridge-staging-main`, not `yabridge-test-infra-main`.
`test-harness/pyproject.toml` `[project.urls] Repository` becomes the
staging URL. Leave `robbert-vdh/yabridge` links.

Remove the gitlink with `git rm yabridge-test-infra` and delete
`.gitmodules`. Do **not** `git submodule deinit` from a checkout that
shares `.git/config` with `main` (that unregisters the main submodule).
If `.worktrees/hygiene` is still registered, `git worktree remove --force`
it before creating the split worktree.

Parent README residual-risks and Related links: drop the submodule
story and the `web/README.md` pointer. One sentence: results submit
to the live site; the server source is private.

## CI

Public repo **does** get `.github/`. Phase 6 forbade parent CI because
parent was a local-only checkout. After this cut, parent is the public
test product. Bring over the four non-web workflows. Do not add
`web.yml` here.

Private repo gets only `web.yml`, paths `web/**` rewritten to the new
root.

## What this is not

- Not a rewrite of isolation, Meson, Alembic, or security behavior
- Not Python lockfiles or Docker digests
- Not unused-role resurrection
- Not pushing unless asked. Creating the GitHub remotes is a last
  task that waits for an explicit go
- Not `git filter-repo` of the old submodule into staging

## Success criteria

- `./setup.sh` / `./test.sh` / `./daw-env.sh` work with harness at
  `test-harness/` and no submodule
- `git ls-files` on the public tree contains no `web/` and no
  `.gitmodules`
- `./scripts/check.sh` is green (web skip is gone; harness optional
  venv still skips if missing)
- Public workflows do not mention `web/`
- A sibling private repo contains only the website and its tests;
  its pytest/CI do not import `test-harness/` or `docs/architecture.md`
- `curl` of the site's `/install.sh` (the `INSTALL_SCRIPT` string)
  clones public staging, not `yabridge-test-infra`
- Nothing is pushed unless asked
  (`derEremit/yabridge-test-infra` is already public with `web/` —
  making it private waits for the publish ask, but do not push the
  66 local combined commits there)
