# Public / Private Repository Split Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Create the isolated worktree with superpowers:using-git-worktrees at execution time (parent `yabridge-staging`, branch `remediate/repo-split`). **Before** `git worktree add`, if `.worktrees/hygiene` is still registered, run `git worktree remove --force .worktrees/hygiene` from parent `main` and `git branch -d remediate/hygiene` (already merged). Do not `git submodule deinit` from a worktree — that shared `.git/config` unhooked `main` once already.

**Goal:** One public tree with isolation + harness + VMs; one private tree that is only the website. No submodule.

**Architecture:** Copy current non-`web/` submodule directories into the parent at top level, retarget every `yabridge-test-infra/test-harness` path, delete the gitlink. Copy `web/` to a new sibling git repo `yabridge-results`. Do not filter-repo. Do not push.

**Tech Stack:** Git, Bash, Bats, GitHub Actions (moved, not invented).

**Spec:** `docs/superpowers/specs/2026-08-27-repo-split-design.md`

## Global Constraints

- Do not copy `web/` into the public tree.
- Do not `git filter-repo` the old submodule into staging.
- Do not add `web.yml` to the public repo.
- Do not push either repository unless the user explicitly asks.
- Do not invent Python lockfiles or Docker digests.
- Do not `import_role` unused Ansible roles; copy the ansible tree as it is.
- Leave `robbert-vdh/yabridge` links. Public clone URL is `https://github.com/derEremit/yabridge-staging`.
- Harness default API URL stays `https://yabridge-tests.fly.dev`.
- System Python is 3.14. Harness/web suites use their `.venv` when present.
- After `test.sh` edits, `setup.sh` `TESTEOF` must stay byte-identical (`tests/docs_hygiene.bats` already asserts this).
- Copy `LICENSE` into both new trees. Merge probe/packer ignore rules into parent `.gitignore` before `git add probe`.
- Do not `git submodule deinit`. Task 3 is `git rm` the gitlink + delete `.gitmodules`.
- Private `yabridge-results` pytest must not import sibling `test-harness/` or `../docs/architecture.md`. Do not copy `web/tests/test_harness_contract.py`.

## File structure

| After | Responsibility |
|---|---|
| `test-harness/` | Public CLI (moved) |
| `probe/` | Public CLAP probe (moved) |
| `packer/`, `ansible/` | Public VM path (moved) |
| `install.sh` | Clones `derEremit/yabridge-staging` |
| `.github/workflows/{test-harness,probe,ansible,build-images}.yml` | Public CI (moved, no `web.yml`) |
| `.gitmodules` | Deleted |
| `yabridge-test-infra/` | Gone from the public worktree |
| `/home/z3n/projects/yabridge-results/` | New private git repo; website as root |

---

### Task 1: Harness at `test-harness/` (no submodule path)

**Files:**
- Create: `test-harness/` (copy from submodule, exclude `.venv`)
- Create: `probe/` (copy from submodule)
- Modify: `setup.sh` (`HARNESS` near the top and inside `TESTEOF`)
- Modify: `test.sh`
- Modify: `scripts/check.sh`
- Modify: `tests/setup_components.bats`
- Modify: `tests/setup_fixture.bash`
- Modify: `tests/setup_harness.bats`
- Modify: `.gitignore` (add `probe/build*/`, `probe/subprojects/clap/`, `probe/subprojects/packagecache/`)
- Create: `LICENSE` (copy from submodule)
- Modify: `test-harness/pyproject.toml` Repository URL after copy
- Modify: `tests/docs_hygiene.bats` only if the heredoc assertion needs the new body

**Interfaces:**
- `HARNESS="$ROOT/test-harness"`
- `test.sh` execs `"$ROOT/test-harness/.venv/bin/yabridge-test"`
- `check.sh` uses `$ROOT/test-harness/.venv/bin/python`
- `check.sh` has no `web/` block
- Fixtures copy `$PROJECT_ROOT/test-harness` → `$FIXTURE/test-harness` and `$FIXTURE_ROOT/test-harness` (no `yabridge-test-infra/` directory name)

Work from `/home/z3n/projects/yabridge-staging/.worktrees/repo-split`.

- [ ] **Step 1: Write the failing path contracts**

Add `tests/repo_split.bats`:

```bash
#!/usr/bin/env bats
load test_helper

@test "setup and test.sh point at top-level test-harness" {
  grep -q 'HARNESS="$ROOT/test-harness"' "$PROJECT_ROOT/setup.sh"
  grep -q 'HARNESS="$ROOT/test-harness"' "$PROJECT_ROOT/test.sh"
  refute grep -q 'yabridge-test-infra/test-harness' "$PROJECT_ROOT/setup.sh"
  refute grep -q 'yabridge-test-infra/test-harness' "$PROJECT_ROOT/test.sh"
}

@test "check.sh has no web suite and uses top-level harness" {
  refute grep -q '/web/' "$PROJECT_ROOT/scripts/check.sh"
  grep -q 'test-harness/.venv/bin/python' "$PROJECT_ROOT/scripts/check.sh"
}

@test "public tree has no gitlink and no web app" {
  refute test -f "$PROJECT_ROOT/.gitmodules"
  refute test -d "$PROJECT_ROOT/web/app"
}
```

`refute test -f` works if `refute` runs the command; `test -f` missing file is status 1, which `refute` accepts. Confirm against `tests/test_helper.bash`. If `refute test` is awkward, use `refute grep` on `git ls-files` after the files exist — for this step, asserting the strings in `setup.sh` is enough for RED.

- [ ] **Step 2: Run and witness failure**

```bash
cd /home/z3n/projects/yabridge-staging/.worktrees/repo-split
bats tests/repo_split.bats tests/docs_hygiene.bats
```

Expected: `HARNESS` still names `yabridge-test-infra/test-harness`.

- [ ] **Step 3: Copy trees and retarget paths**

```bash
# from the worktree; do not copy venvs, caches, or probe build trees
rsync -a --exclude '.venv' --exclude '__pycache__' --exclude '.pytest_cache' \
  yabridge-test-infra/test-harness/ test-harness/
rsync -a \
  --exclude '.venv' --exclude '__pycache__' \
  --exclude 'build-*' --exclude 'subprojects/clap' \
  --exclude 'subprojects/packagecache' --exclude 'subprojects/.wraplock' \
  yabridge-test-infra/probe/ probe/
cp yabridge-test-infra/LICENSE LICENSE
```

Append to parent `.gitignore`:

```
probe/build*/
probe/subprojects/clap/
probe/subprojects/packagecache/
probe/subprojects/.wraplock
```

Set `test-harness/pyproject.toml` `[project.urls] Repository` to
`https://github.com/derEremit/yabridge-staging`.

Then edit `setup.sh`, `test.sh`, `scripts/check.sh`,
`tests/setup_components.bats`, `tests/setup_fixture.bash`, and
`tests/setup_harness.bats` so every harness path is
`$ROOT/test-harness` / `$FIXTURE/test-harness` /
`$FIXTURE_ROOT/test-harness`. Delete the web block from `check.sh`.
Keep `TESTEOF` identical to `test.sh`.

Do not delete the submodule yet (Task 3). Do not copy `web/`.

- [ ] **Step 4: Re-run focused bats**

```bash
bats tests/repo_split.bats tests/docs_hygiene.bats tests/setup_cli.bats \
  tests/setup_components.bats tests/setup_harness.bats
```

Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add test-harness probe LICENSE .gitignore setup.sh test.sh scripts/check.sh tests
git commit -m "$(cat <<'EOF'
feat: vendor the harness and probe in the public tree

The submodule mixed a website with the tests. Isolation now
depends on top-level test-harness/, not a gitlink.
EOF
)"
```

---

### Task 2: Packer, Ansible, install.sh, infra docs

**Files:**
- Create: `packer/`, `ansible/`, `install.sh` (copy)
- Create: infra docs that are not operator-only, from `yabridge-test-infra/docs/` (`coord-probe.md`, `getting-started.md`, `test-protocol.md`; `architecture.md` only if you strip website-operator chapters — otherwise skip it and keep parent README)
- Create: `tests/test_packer_nocloud.py`, `tests/test_ansible_build.py` with `ROOT` still `parents[1]`
- Create: `.github/workflows/{test-harness,probe,ansible,build-images}.yml` in **this** task (Task 4 only locks “no web.yml”). `test_ansible_build.py` reads `ansible.yml` at collection time.
- Modify: `install.sh` `REPO_URL` to `https://github.com/derEremit/yabridge-staging`
- Modify: tarball fallback `yabridge-test-infra-main` → `yabridge-staging-main`
- Modify: copied `docs/getting-started.md` — delete the “Running the Results Server” chapter (`cd web`). Drop `contributing.md` links or rewrite and copy that file with the staging clone URL.

**Interfaces:**
- Packer/Ansible tests resolve `packer/http` and `ansible/playbooks` from the public root
- `install.sh` clones the public staging URL and does not mention `yabridge-test-infra`
- The four public workflows exist; `web.yml` does not
- No `web/` in the copy

- [ ] **Step 1: Extend failing URL/layout tests**

Add to `tests/repo_split.bats` or a small `tests/test_clone_url.py` at the public root:

```python
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def test_install_sh_clones_public_staging() -> None:
    text = (ROOT / "install.sh").read_text()
    assert "https://github.com/derEremit/yabridge-staging" in text
    assert "yabridge-test-infra" not in text
    assert "yabridge-staging-main" in text
```

- [ ] **Step 2: Run and witness FileNotFoundError / old URL**

- [ ] **Step 3: Copy and retarget**

```bash
rsync -a yabridge-test-infra/packer/ packer/
rsync -a yabridge-test-infra/ansible/ ansible/
cp yabridge-test-infra/install.sh install.sh
# docs:
mkdir -p docs
cp yabridge-test-infra/docs/coord-probe.md docs/coord-probe.md
cp yabridge-test-infra/docs/getting-started.md docs/getting-started.md
cp yabridge-test-infra/docs/test-protocol.md docs/test-protocol.md
cp yabridge-test-infra/tests/test_packer_nocloud.py tests/test_packer_nocloud.py
cp yabridge-test-infra/tests/test_ansible_build.py tests/test_ansible_build.py
mkdir -p .github/workflows
cp yabridge-test-infra/.github/workflows/test-harness.yml .github/workflows/
cp yabridge-test-infra/.github/workflows/probe.yml .github/workflows/
cp yabridge-test-infra/.github/workflows/ansible.yml .github/workflows/
cp yabridge-test-infra/.github/workflows/build-images.yml .github/workflows/
# do not copy web.yml
```

Edit `install.sh` (`REPO_URL` and tarball dir). Strip the results-server chapter from `docs/getting-started.md`. Do not copy `docs/contributing.md` unless you rewrite its clone URL; remove the Next Steps link to it if you skip the file.

- [ ] **Step 4: Run packer/ansible/clone tests + `bats tests/repo_split.bats`**

```bash
python3 -m pytest -q tests/test_packer_nocloud.py tests/test_ansible_build.py tests/test_clone_url.py
bats tests/repo_split.bats
```

Expected: pass (`ansible-playbook` syntax-check may need `ANSIBLE_LOCAL_TEMP` under the worktree).

- [ ] **Step 5: Commit**

```bash
git add packer ansible install.sh docs tests .github
git commit -m "$(cat <<'EOF'
feat: land Packer, Ansible, and install.sh in the public tree

VM definitions and the installer belong with the tests, not
with the private results server.
EOF
)"
```

---

### Task 3: Remove the submodule

**Files:**
- Delete: `.gitmodules`
- Delete: `yabridge-test-infra` gitlink (stop tracking the submodule)
- Modify: `.gitignore` if it mentions the submodule specially
- Modify: `README.md` directory layout and Related links (minimal in this task: layout + clone line; Residual risks fully in Task 5)

**Interfaces:**
- `git ls-files` has no `yabridge-test-infra`
- `test -d web/app` is false in the public worktree
- `refute test -f .gitmodules` now passes

- [ ] **Step 1: The Task 1 bats for no gitlink / no `web/app` should still be RED until this task** (if you left the submodule in place). Re-run `bats tests/repo_split.bats` and witness the gitlink assertion fail if it still does.

- [ ] **Step 2: Remove the gitlink without deinit**

From the worktree only:

```bash
git rm -f yabridge-test-infra
git rm -f .gitmodules
```

Do **not** run `git submodule deinit`. That writes shared `.git/config` and can unregister `main`'s submodule.

- [ ] **Step 3: Confirm `git ls-files` has no `yabridge-test-infra` and no `web/`**

- [ ] **Step 4: Re-run the harness bats, including the omitted files**

```bash
bats tests/repo_split.bats tests/setup_cli.bats tests/setup_components.bats \
  tests/setup_harness.bats tests/docs_hygiene.bats
```

Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
chore: drop the test-infra submodule

The public tree now has the tests in-repo. The website is not
part of this checkout.
EOF
)"
```

---

### Task 4: Lock public CI (no website workflow)

**Files:**
- Modify: none unless Task 2 missed a workflow
- Test: `tests/test_public_ci.py`

The four workflows were copied in Task 2 so `test_ansible_build.py` could collect. This task only proves `web.yml` is absent and no workflow text mentions `web/`.

- [ ] **Step 1: Failing workflow test**

```python
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WF = ROOT / ".github" / "workflows"


def test_public_workflows_exclude_the_website() -> None:
    names = {p.name for p in WF.glob("*.yml")}
    assert names == {
        "test-harness.yml",
        "probe.yml",
        "ansible.yml",
        "build-images.yml",
    }
    assert not (WF / "web.yml").exists()
    for path in WF.glob("*.yml"):
        assert "web/" not in path.read_text()
```

Put this in `tests/test_clone_url.py` or `tests/test_public_ci.py`.

- [ ] **Step 2: Run the test**

If Task 2 copied the four files and omitted `web.yml`, this is GREEN immediately — still commit the lock test. If it fails, add the missing workflow from submodule `76b95b3`; do not add `web.yml`.

- [ ] **Step 3: Confirm `web.yml` is absent and no workflow contains `web/`**

- [ ] **Step 4: Re-run `python3 -m pytest -q tests/test_public_ci.py tests/test_ansible_build.py`**

- [ ] **Step 5: Commit**

```bash
git add tests/test_public_ci.py
git commit -m "$(cat <<'EOF'
test: lock public CI to the four non-web workflows

The website workflow belongs in yabridge-results, not here.
EOF
)"
```

---

### Task 5: Private `yabridge-results` and public README

**Files:**
- Create: `/home/z3n/projects/yabridge-results/` as a **new git repo** (not a worktree of staging)
- Modify: parent `README.md` layout, Residual risks (no submodule story), Related (no `web/README.md` link)
- Modify: copied getting-started clone lines if Task 2 left any `yabridge-test-infra` clones

**Interfaces:**
- Private repo root has `app/`, `requirements.txt`, `fly.toml`, `Dockerfile`, `alembic/`, `tests/`, `LICENSE`, `.github/workflows/web.yml` (jobs at repo root)
- Private `git ls-files` has no `test-harness/`, `packer/`, `daw-env.sh`, or `tests/test_harness_contract.py`
- `INSTALL_SCRIPT` in `app/main.py` clones `https://github.com/derEremit/yabridge-staging`
- Public README clone is `git clone https://github.com/derEremit/yabridge-staging` with no recurse-submodules
- Public README does not link into a `web/` path

- [ ] **Step 1: Write a failing public-README test**

```bash
@test "README clones staging without a submodule" {
  grep -q 'github.com/derEremit/yabridge-staging' "$PROJECT_ROOT/README.md"
  refute grep -q 'recurse-submodules' "$PROJECT_ROOT/README.md"
  refute grep -q 'yabridge-test-infra/web' "$PROJECT_ROOT/README.md"
}
```

- [ ] **Step 2: Run and witness failure**

- [ ] **Step 3: Extract the website and rewrite README**

```bash
mkdir -p /home/z3n/projects/yabridge-results
# copy from the submodule checkout still on disk at
# /home/z3n/projects/yabridge-staging/yabridge-test-infra/web
# (main checkout, even if the worktree already dropped the gitlink)
rsync -a --exclude '.venv' --exclude '__pycache__' --exclude 'data' \
  --exclude 'tests/test_harness_contract.py' \
  /home/z3n/projects/yabridge-staging/yabridge-test-infra/web/ \
  /home/z3n/projects/yabridge-results/
cp /home/z3n/projects/yabridge-staging/yabridge-test-infra/LICENSE \
  /home/z3n/projects/yabridge-results/LICENSE
# copy and fix web.yml into /home/z3n/projects/yabridge-results/.github/workflows/web.yml
```

In `yabridge-results/.github/workflows/web.yml`: drop `working-directory: web` and `web/**` path filters; use repo root. `cache-dependency-path` becomes `requirements.txt` / `requirements-dev.txt`.

In the private tree, retarget tests and the live installer **before** `git add`:

- `tests/test_quality_config.py`: `ROOT = Path(__file__).resolve().parents[1]`; `PYPROJECT = ROOT / "pyproject.toml"`; workflow `paths` without `web/`; drop the `working-directory == "web"` assertion.
- `tests/test_operations_docs.py`: delete `ARCHITECTURE` / `REPO_ROOT / "docs"` reads; keep `README = WEB_ROOT / "README.md"` with `WEB_ROOT = Path(__file__).resolve().parent.parent` (now the private root).
- `app/main.py` `INSTALL_SCRIPT`: `REPO_URL="https://github.com/derEremit/yabridge-staging"`; tarball dir `yabridge-staging-main`; `cd "$INSTALL_DIR/repo/test-harness"` stays valid.
- `templates/base.html`: drop or retarget the Source href away from `github.com/yabridge/yabridge-test-infra`.
- `fly.toml`: comment names the private results server, not `yabridge-test-infra`.

```bash
cd /home/z3n/projects/yabridge-results
git init
git add .
git commit -m "$(cat <<'EOF'
feat: private results server

Website source only. Not the public test tree.
EOF
)"
```

Do not `git remote add` and do not push.

Rewrite parent README. Residual risks: this parent is the public test repo; the results server source is private; submit URL is the live site.

- [ ] **Step 4: Re-run public bats + `./scripts/check.sh`**

Expected: public check green. Optional harness venv may skip. No web skip line (block removed).

In `yabridge-results`, if `web/.venv` was not copied, skip running the web suite here unless a venv exists. Do not fail the public task on a missing private venv.

- [ ] **Step 5: Commit the public README (and any leftover path docs) in the staging worktree only**

```bash
git add README.md docs tests
git commit -m "$(cat <<'EOF'
docs: describe a single public test repo

Clone staging; there is no submodule. The results server
source is not in this tree.
EOF
)"
```

Do not merge, do not add remotes, do not push. The controller uses finishing-a-development-branch. Making `derEremit/yabridge-test-infra` private on GitHub and adding a public `yabridge-staging` remote wait for an explicit publish ask.

---

## Self-review

| Spec item | Task |
|---|---|
| Harness/probe at top level; check.sh without web | 1 |
| Packer/Ansible/install.sh public | 2 |
| No gitlink, no `web/` in public tree | 3 |
| Four public workflows copied with Ansible tests; no `web.yml` lock | 2 + 4 |
| Private `yabridge-results` (CI/tests/INSTALL_SCRIPT retargeted); README; no push | 5 |
| No filter-repo; no lockfiles | Global constraints |
