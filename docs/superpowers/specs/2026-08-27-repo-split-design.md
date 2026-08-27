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
- `install.sh` (clones this public repo)
- infra docs that are not operator-only (`docs/coord-probe.md`,
  `docs/getting-started.md`, `docs/test-protocol.md`; trim website
  chapters out of `docs/architecture.md` or leave a one-line pointer
  at the live site)
- `.github/workflows/`: `test-harness.yml`, `probe.yml`, `ansible.yml`,
  `build-images.yml` (same pins as today)
- `tests/test_packer_nocloud.py`, `tests/test_ansible_build.py` (paths
  updated)

Gone from the public tree:

- `.gitmodules` and the `yabridge-test-infra` gitlink
- `web/`
- `.github/workflows/web.yml`

`scripts/check.sh` runs shellcheck, parent bats, then optional
`test-harness/.venv` pytest. It does **not** look for a web venv.

## Private tree layout

A new git repository whose first commit is the current `web/` directory
as the repo root (today's `web/app` becomes `app/`, and so on). Copy
`web.yml` to `.github/workflows/web.yml` and fix `working-directory`
(jobs already `cd` to `web/` — they become repo-root).

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
bats that `cp -R` the harness into a fixture (`tests/setup_components.bats`)
use the new path. The fixture directory name `yabridge-test-infra` can
die; copy into `$FIXTURE/test-harness`.

`install.sh` and clone-URL tests point at
`https://github.com/derEremit/yabridge-staging`, not
`derEremit/yabridge-test-infra`. Leave `robbert-vdh/yabridge` links.

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
- A sibling private repo contains only the website and its tests
- Nothing is pushed unless asked
