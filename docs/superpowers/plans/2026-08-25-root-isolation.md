# Root Isolation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make root setup reproducible and ensure isolated DAW runs use only cloned plugin targets behind a Bubblewrap read-only boundary.

**Architecture:** Root scripts will share small, sourceable helpers under `lib/`, with behavior covered by Bats fixtures. Setup will compare requested component identities against recorded state instead of trusting file existence. DAW runs will create an isolated `HOME`/XDG configuration, run `yabridgectl` against the cloned prefix, and execute the DAW through Bubblewrap with production paths read-only.

**Tech Stack:** Bash 5, Bats, Git, Meson/Ninja, yabridgectl, GNU coreutils, Bubblewrap 0.11+, Wine

**Spec:** `docs/superpowers/specs/2026-08-25-yabridge-staging-remediation-design.md`

## Global Constraints

- Production Wine prefixes and plugin directories must never be writable during isolated runs.
- Existing production yabridge bridge directories must not be used by isolated runs.
- No test may mutate the real prefix; all shell tests use temporary fixture trees and fake executables.
- Downloaded executable artifacts require an expected SHA-256 before extraction.
- Existing generated files remain ignored by Git.
- Every behavior change follows a witnessed red-green test cycle.

---

### Task 1: Establish the root Bats test boundary

**Files:**
- Create: `tests/test_helper.bash`
- Create: `tests/setup_cli.bats`
- Modify: `setup.sh:19-42`
- Modify: `daw-env.sh:43-69`

**Interfaces:**
- Produces: `run_setup()` and `run_daw_env()` Bats helpers.
- Produces: both scripts return exit 0 for `--help` and exit 2 with a clear message when an option value is missing.

- [ ] **Step 1: Write failing CLI tests**

```bash
#!/usr/bin/env bats

load test_helper

@test "setup help exits successfully" {
  run_setup --help
  [ "$status" -eq 0 ]
}

@test "setup rejects a missing wine version" {
  run_setup --wine-version
  [ "$status" -eq 2 ]
  [[ "$output" == *"--wine-version requires a value"* ]]
}

@test "DAW launcher rejects a missing prefix value" {
  run_daw_env --prefix
  [ "$status" -eq 2 ]
  [[ "$output" == *"--prefix requires a value"* ]]
}
```

`tests/test_helper.bash`:

```bash
PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

run_setup() {
  run "$PROJECT_ROOT/setup.sh" "$@"
}

run_daw_env() {
  run "$PROJECT_ROOT/daw-env.sh" "$@"
}
```

- [ ] **Step 2: Run tests and verify the current behavior fails**

Run: `bats tests/setup_cli.bats`

Expected: help exits 1 and missing option values fail with an unbound-variable message.

- [ ] **Step 3: Implement explicit option-value checks**

Add a success status parameter to `usage()`:

```bash
usage() {
    local status="${1:-1}"
    echo "Usage: $0 [--wine-version VERSION] [--yabridge-branch REF] [--no-wine] [--no-yabridge]"
    exit "$status"
}
```

Before consuming an option value:

```bash
require_option_value() {
    local option="$1"
    local value="${2:-}"
    if [[ -z "$value" ]]; then
        err "$option requires a value"
        exit 2
    fi
}
```

Use `usage 0` for help, and perform the same `${2:-}` guard in `daw-env.sh`.

- [ ] **Step 4: Run focused and static checks**

Run:

```bash
bats tests/setup_cli.bats
bash -n setup.sh daw-env.sh
shellcheck -e SC1091 setup.sh daw-env.sh tests/test_helper.bash
```

Expected: all commands exit 0.

- [ ] **Step 5: Commit**

```bash
git add setup.sh daw-env.sh tests/
git commit -m "test: establish root shell behavior"
```

### Task 2: Honor requested Wine and yabridge identities

**Files:**
- Create: `lib/component-state.sh`
- Create: `tests/component_state.bats`
- Create: `tests/setup_components.bats`
- Modify: `setup.sh:28-178`
- Modify: `.gitignore`

**Interfaces:**
- Produces: `read_state KEY FILE`, `write_state FILE KEY=VALUE...`, and `component_matches KEY EXPECTED FILE`.
- Produces: generated `build/component-state.env` containing `WINE_VERSION`, `WINE_SHA256`, `YABRIDGE_REF`, and `YABRIDGE_COMMIT`.
- Setup rebuilds or downloads whenever requested identity and recorded identity differ.

- [ ] **Step 1: Write failing state helper tests**

```bash
#!/usr/bin/env bats

load test_helper

setup() {
  STATE="$BATS_TEST_TMPDIR/component-state.env"
  source "$PROJECT_ROOT/lib/component-state.sh"
}

@test "component state round-trips exact values" {
  write_state "$STATE" \
    "WINE_VERSION=11.8" \
    "WINE_SHA256=6c6f642b0954248493ebbd86ec232c46a6b9cf97c747ab3f1bcb707a22efed1d" \
    "YABRIDGE_COMMIT=48ea9749b682c48875366134a42073d6b3d0a8c4"
  [ "$(read_state WINE_VERSION "$STATE")" = "11.8" ]
  component_matches YABRIDGE_COMMIT 48ea9749b682c48875366134a42073d6b3d0a8c4 "$STATE"
}

@test "state values cannot inject shell syntax" {
  write_state "$STATE" 'WINE_VERSION=$(touch injected)'
  run read_state WINE_VERSION "$STATE"
  [ "$status" -eq 1 ]
  [ ! -e "$BATS_TEST_TMPDIR/injected" ]
}
```

- [ ] **Step 2: Run tests and verify the helper is absent**

Run: `bats tests/component_state.bats`

Expected: FAIL because `lib/component-state.sh` does not exist.

- [ ] **Step 3: Implement a non-evaluating state format**

Use strict key/value parsing rather than `source`:

```bash
read_state() {
    local key="$1" file="$2" line
    [[ "$key" =~ ^[A-Z0-9_]+$ && -f "$file" ]] || return 1
    line="$(grep -E "^${key}=[A-Za-z0-9._:/+@-]+$" "$file" | tail -n 1)" || return 1
    printf '%s\n' "${line#*=}"
}
```

Write via a temporary file in the same directory followed by `mv`.

- [ ] **Step 4: Write failing setup cache tests**

Create fake `curl`, `git`, `meson`, and `ninja` commands that append invocations
to `$BATS_TEST_TMPDIR/calls`. Execute setup against a temporary project fixture.
Assert:

```bash
@test "different requested Wine version replaces cached Wine" {
  seed_component_state WINE_VERSION 11.7
  run_setup_fixture --wine-version 11.8 --wine-sha256 "$WINE_11_8_SHA"
  [ "$status" -eq 0 ]
  grep -q "curl .*wine-11.8-staging-amd64.tar.xz" "$CALLS"
}

@test "different yabridge ref fetches and rebuilds" {
  seed_component_state YABRIDGE_COMMIT old-commit
  run_setup_fixture --no-wine --yabridge-branch 48ea9749b682c48875366134a42073d6b3d0a8c4
  grep -q "git .*checkout.*48ea974" "$CALLS"
  grep -q "ninja" "$CALLS"
}
```

- [ ] **Step 5: Run cache tests and verify stale reuse**

Run: `bats tests/setup_components.bats`

Expected: FAIL because setup accepts existing output files without identity checks.

- [ ] **Step 6: Implement identity comparison and forced refresh**

Add `--wine-sha256 SHA256`. For explicit or locked Wine versions, reject a
missing digest. Resolve the yabridge ref to a full commit after fetch and rebuild
when it differs from recorded state. Configure Meson with
`meson setup --wipe` when a build directory already exists.

- [ ] **Step 7: Verify focused behavior**

Run:

```bash
bats tests/component_state.bats tests/setup_components.bats
bash -n setup.sh lib/component-state.sh
shellcheck -e SC1091 setup.sh lib/component-state.sh tests/*.bash
```

Expected: all commands exit 0.

- [ ] **Step 8: Commit**

```bash
git add .gitignore setup.sh lib/component-state.sh tests/
git commit -m "fix: honor requested component revisions"
```

### Task 3: Verify Wine archives and install the harness

**Files:**
- Create: `tests/setup_integrity.bats`
- Create: `tests/setup_harness.bats`
- Modify: `setup.sh:112-131, 184-265`
- Modify: `README.md:49-79, 214-236`

**Interfaces:**
- Setup validates `sha256sum -c` before extraction.
- Setup extracts into a temporary build directory and atomically renames it.
- Setup creates `test-harness/.venv`, installs the local package, and executes the venv entrypoint explicitly from `test.sh`.

- [ ] **Step 1: Write a failing checksum test**

```bash
@test "setup rejects a Wine archive with the wrong digest" {
  seed_archive "tampered"
  run_setup_fixture --wine-version 11.8 --wine-sha256 \
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    --no-yabridge
  [ "$status" -ne 0 ]
  [[ "$output" == *"Wine archive checksum mismatch"* ]]
  [ ! -e "$FIXTURE_ROOT/build/wine/bin/wine" ]
}
```

- [ ] **Step 2: Run the checksum test and verify it fails**

Run: `bats tests/setup_integrity.bats`

Expected: FAIL because the current setup extracts without verification.

- [ ] **Step 3: Implement checksum and atomic extraction**

Validate SHA syntax, run:

```bash
printf '%s  %s\n' "$WINE_SHA256" "$TARBALL" | sha256sum -c -
```

Reject archive entries beginning with `/` or containing `../`, extract into
`mktemp -d "$BUILD/.wine-extract.XXXXXX"`, verify `bin/wine`, then rename into
`build/wine`.

- [ ] **Step 4: Write failing harness installation tests**

```bash
@test "setup installs the local harness into its venv" {
  run_setup_fixture --no-wine --no-yabridge
  [ -x "$FIXTURE_ROOT/yabridge-test-infra/test-harness/.venv/bin/yabridge-test" ]
}

@test "test wrapper never falls back to a global command" {
  run grep -F 'exec "$HARNESS/.venv/bin/yabridge-test" "$@"' "$FIXTURE_ROOT/test.sh"
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 5: Implement deterministic harness installation**

Create the venv with `python3 -m venv`, install the local project with
`python -m pip install --disable-pip-version-check -e "$HARNESS"`, and generate
`test.sh` with preflight checks that execute the absolute venv binary.

- [ ] **Step 6: Verify and commit**

Run:

```bash
bats tests/setup_integrity.bats tests/setup_harness.bats
bash -n setup.sh
shellcheck -e SC1091 setup.sh
```

Then:

```bash
git add setup.sh README.md tests/
git commit -m "fix: verify Wine and install test harness"
```

### Task 4: Bind cached clones to their source

**Files:**
- Create: `lib/clone-state.sh`
- Create: `tests/daw_clone.bats`
- Modify: `daw-env.sh:71-124`
- Modify: `.gitignore`

**Interfaces:**
- Produces: `prefix-copy/.yabridge-staging-source` containing canonical source path and source device/inode.
- Existing clones are reused only when provenance matches.
- Produces: `--refresh-bridges` independently of `--fresh`.

- [ ] **Step 1: Write failing provenance tests**

```bash
@test "launcher refuses a clone created from another source prefix" {
  make_prefix "$BATS_TEST_TMPDIR/source-a"
  make_prefix "$BATS_TEST_TMPDIR/source-b"
  make_clone_for "$BATS_TEST_TMPDIR/source-a"

  run_daw_fixture --prefix "$BATS_TEST_TMPDIR/source-b" fake-daw

  [ "$status" -ne 0 ]
  [[ "$output" == *"clone belongs to a different source prefix"* ]]
}
```

- [ ] **Step 2: Run and verify stale clone reuse**

Run: `bats tests/daw_clone.bats`

Expected: FAIL because the launcher reuses any existing `prefix-copy`.

- [ ] **Step 3: Implement atomic clone provenance**

Clone into `prefix-copy.new.$$`, write provenance only after a successful
reflink copy, then rename. Reject source/clone equality, nested paths, symlinked
destinations, and provenance mismatch.

- [ ] **Step 4: Verify and commit**

Run:

```bash
bats tests/daw_clone.bats
bash -n daw-env.sh lib/clone-state.sh
shellcheck -e SC1091 daw-env.sh lib/clone-state.sh
```

Then:

```bash
git add .gitignore daw-env.sh lib/clone-state.sh tests/daw_clone.bats
git commit -m "fix: bind cached clones to their source"
```

### Task 5: Generate bridges that target only the clone

**Files:**
- Create: `lib/isolated-bridges.sh`
- Create: `tests/isolated_bridges.bats`
- Modify: `daw-env.sh:106-135`
- Modify: `.gitignore`

**Interfaces:**
- Produces: `prepare_isolated_bridges ROOT COPY YABRIDGECTL YABRIDGE_HOME`.
- Uses `isolation/home` for `HOME`, `XDG_CONFIG_HOME`, and `XDG_DATA_HOME`.
- Produces bridges under `isolation/home/.vst/yabridge`, `.vst3/yabridge`, and `.clap/yabridge`.
- Every Windows target resolved from generated bridge metadata must canonicalize under `prefix-copy`.

- [ ] **Step 1: Write failing bridge-environment tests**

```bash
@test "bridge sync receives only the clone as a plugin directory" {
  run prepare_isolated_bridges \
    "$FIXTURE_ROOT" "$FIXTURE_ROOT/prefix-copy" "$FAKE_YABRIDGECTL" "$YABRIDGE_HOME"
  [ "$status" -eq 0 ]
  grep -Fx "add $FIXTURE_ROOT/prefix-copy" "$CALLS"
  ! grep -F "$REAL_PREFIX" "$CALLS"
}

@test "bridge validation rejects targets outside the clone" {
  create_bridge_target "$ISOLATED_HOME/.vst/yabridge/Evil.so" "$REAL_PREFIX/Evil.dll"
  run validate_bridge_targets "$ISOLATED_HOME" "$COPY"
  [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run and verify the helper is absent**

Run: `bats tests/isolated_bridges.bats`

Expected: FAIL because `lib/isolated-bridges.sh` does not exist.

- [ ] **Step 3: Implement isolated yabridgectl execution**

Run yabridgectl with:

```bash
env \
  HOME="$ISOLATED_HOME" \
  XDG_CONFIG_HOME="$ISOLATED_HOME/.config" \
  XDG_DATA_HOME="$ISOLATED_HOME/.local/share" \
  "$YABRIDGECTL" set --path="$YABRIDGE_HOME"
```

Add only the clone root, run `sync --force --prune`, and validate every generated
`.dll`, `.vst3-win`, and `.clap-win` target after canonicalization. Refuse empty
bridge output unless `--allow-empty` was explicitly supplied.

- [ ] **Step 4: Expose isolated plugin paths to the DAW**

Set `VST_PATH`, `VST3_PATH`, and `CLAP_PATH` to the isolated bridge directories
without appending production bridge directories. Preserve native system plugin
paths only through an explicit `--native-plugin-path` option.

- [ ] **Step 5: Verify and commit**

Run:

```bash
bats tests/isolated_bridges.bats
bash -n daw-env.sh lib/isolated-bridges.sh
shellcheck -e SC1091 daw-env.sh lib/isolated-bridges.sh
```

Then:

```bash
git add .gitignore daw-env.sh lib/isolated-bridges.sh tests/
git commit -m "feat: generate clone-only yabridge bridges"
```

### Task 6: Enforce the Bubblewrap boundary

**Files:**
- Create: `lib/sandbox.sh`
- Create: `tests/sandbox.bats`
- Modify: `daw-env.sh:126-135`
- Modify: `README.md:95-160`

**Interfaces:**
- Produces: `build_bwrap_command OUTPUT_ARRAY DAW ARGS...`.
- Bubblewrap read-only binds `/usr`, `/etc`, production prefix, and production plugin roots.
- Bubblewrap read-write binds the clone, isolated home, runtime directory, and explicitly approved project/output paths.
- Launcher fails closed if Bubblewrap or required namespace support is unavailable.

- [ ] **Step 1: Write failing command-construction tests**

```bash
@test "sandbox mounts production prefix read-only and clone writable" {
  build_bwrap_command command fake-daw
  assert_sequence "${command[@]}" --ro-bind "$REAL_PREFIX" "$REAL_PREFIX"
  assert_sequence "${command[@]}" --bind "$COPY" "$COPY"
}

@test "sandbox never binds production yabridge directories writable" {
  build_bwrap_command command fake-daw
  refute_writable_bind "${command[@]}" "$HOME/.vst/yabridge"
  refute_writable_bind "${command[@]}" "$HOME/.vst3/yabridge"
  refute_writable_bind "${command[@]}" "$HOME/.clap/yabridge"
}
```

- [ ] **Step 2: Run and verify the helper is absent**

Run: `bats tests/sandbox.bats`

Expected: FAIL because `lib/sandbox.sh` does not exist.

- [ ] **Step 3: Implement a fail-closed Bubblewrap command**

Build an argv array, never an evaluated string. Use a new mount namespace,
`--die-with-parent`, `--new-session`, read-only system binds, `/proc`, `/dev`,
tmpfs `/tmp`, the current user runtime socket paths required by the DAW, and
explicit writable binds only for the clone and isolation state. Do not use
`--share-net` unless a new `--network` option is supplied.

- [ ] **Step 4: Add a fixture mutation integration test**

Execute a fake DAW that attempts:

```bash
printf changed >"$REAL_PREFIX/drive_c/production.txt"
printf changed >"$COPY/drive_c/clone.txt"
```

Assert the production write fails, the original checksum is unchanged, and the
clone write succeeds.

- [ ] **Step 5: Run focused and safe integration checks**

Run:

```bash
bats tests/sandbox.bats
bash -n daw-env.sh lib/sandbox.sh
shellcheck -e SC1091 daw-env.sh lib/sandbox.sh
```

Expected: all tests pass; the fixture production tree remains unchanged.

- [ ] **Step 6: Commit**

```bash
git add daw-env.sh lib/sandbox.sh tests/sandbox.bats README.md
git commit -m "feat: enforce read-only production plugin boundary"
```

### Task 7: Record run identity and complete phase verification

**Files:**
- Create: `lib/run-manifest.sh`
- Create: `tests/run_manifest.bats`
- Modify: `daw-env.sh`
- Modify: `setup.sh`
- Modify: `README.md`

**Interfaces:**
- Produces: `isolation/run-manifest.json` with schema version, UTC timestamp,
  source/clone paths, source device/inode, Wine version/digest, yabridge
  ref/commit, bridge root, DAW path, sandbox status, and network status.
- Default Wine diagnostics are preserved; `--quiet-wine` sets `WINEDEBUG=-all`.

- [ ] **Step 1: Write a failing manifest test**

```bash
@test "run manifest records exact executable identities" {
  write_run_manifest "$MANIFEST"
  run python - "$MANIFEST" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
assert data["schema_version"] == 1
assert len(data["yabridge_commit"]) == 40
assert len(data["wine_sha256"]) == 64
assert data["sandbox"]["enabled"] is True
PY
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run and verify the writer is absent**

Run: `bats tests/run_manifest.bats`

Expected: FAIL because no manifest writer exists.

- [ ] **Step 3: Implement atomic JSON manifest generation**

Pass values as environment variables to a short embedded Python encoder; do not
construct JSON with shell string interpolation. Write to a sibling temporary
file and rename.

- [ ] **Step 4: Run the complete root verification suite**

Run:

```bash
bats tests/*.bats
bash -n setup.sh daw-env.sh lib/*.sh
shellcheck -e SC1091 setup.sh daw-env.sh lib/*.sh tests/*.bash
./setup.sh --help
./daw-env.sh --help
git diff --check
```

Expected: all commands exit 0 with no test failures or syntax errors.

- [ ] **Step 5: Commit**

```bash
git add setup.sh daw-env.sh README.md lib/run-manifest.sh tests/run_manifest.bats
git commit -m "feat: record isolated run provenance"
```

### Task 8: Review phase-one changes

**Files:**
- Review: all changes since `cc676c8`

**Interfaces:**
- Consumes: completed Tasks 1–7.
- Produces: an evidence-backed review with no unresolved Critical or High issue in the phase-one scope.

- [ ] **Step 1: Run the complete verification commands from Task 7**

Expected: all exit 0.

- [ ] **Step 2: Request a repository code review**

Review `cc676c8..HEAD` for destructive path handling, shell injection,
TOCTOU/symlink races, Bubblewrap escapes, accidental production plugin paths,
and mismatch between tests and real yabridgectl behavior.

- [ ] **Step 3: Address every Critical and High review finding with a new red-green cycle**

Each fix receives its own regression test and focused commit.

- [ ] **Step 4: Verify clean state**

Run:

```bash
git status --short --branch
git log --oneline cc676c8..HEAD
```

Expected: clean `main` and a reviewable sequence of phase-one commits.
