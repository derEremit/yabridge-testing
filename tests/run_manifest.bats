#!/usr/bin/env bats

load test_helper

setup() {
  MANIFEST_TREE="$BATS_TEST_TMPDIR/staged"
}

# ── Launcher fixture ─────────────────────────────────────────────────────────
#
# A whole project the launcher can run against: its own production home, source
# prefix, generated environment, component state and fake executables. Nothing
# here reads or writes the real home. Bubblewrap is stubbed by the shared fake,
# which records its argv and then runs the command it was given, so this suite
# stays independent of host namespace policy; tests/sandbox.bats covers real
# Bubblewrap enforcement.
stage_launcher_fixture() {
  FIXTURE_ROOT="$BATS_TEST_TMPDIR/project"
  FIXTURE_BIN="$BATS_TEST_TMPDIR/bin"
  PRODUCTION_HOME="$BATS_TEST_TMPDIR/production-home"
  REAL_PREFIX="$PRODUCTION_HOME/.audio-production/winplugins"
  COPY="$FIXTURE_ROOT/prefix-copy"
  ISOLATION="$FIXTURE_ROOT/isolation"
  ISOLATED_HOME="$ISOLATION/home"
  LAUNCHER_MANIFEST="$ISOLATION/run-manifest.json"
  YABRIDGE_HOME="$FIXTURE_ROOT/build/yabridge"
  STATE_FILE="$FIXTURE_ROOT/build/component-state.env"
  BWRAP_CALLS="$BATS_TEST_TMPDIR/bwrap.calls"
  CALLS="$BATS_TEST_TMPDIR/yabridgectl.calls"
  DAW_ENV_FILE="$BATS_TEST_TMPDIR/daw-env.out"

  mkdir -p "$FIXTURE_BIN" "$YABRIDGE_HOME" \
    "$PRODUCTION_HOME/.vst/yabridge" "$PRODUCTION_HOME/.vst3/yabridge" \
    "$PRODUCTION_HOME/.clap/yabridge"
  printf '%s\n' 'chainloader' > "$YABRIDGE_HOME/libyabridge-chainloader-vst2.so"
  make_prefix "$REAL_PREFIX"
  cp "$PROJECT_ROOT/daw-env.sh" "$FIXTURE_ROOT/daw-env.sh"
  chmod +x "$FIXTURE_ROOT/daw-env.sh"
  copy_launcher_libraries "$FIXTURE_ROOT/lib"
  seed_component_state_file "$STATE_FILE"

  # A generated environment from before Wine diagnostics became the caller's
  # decision. A launch must not inherit this silencing.
  cat > "$FIXTURE_ROOT/env.sh" <<EOF
export WINELOADER="$FIXTURE_BIN/wine"
export WINESERVER="$FIXTURE_BIN/wineserver"
export WINEDLLPATH="$BATS_TEST_TMPDIR/winedll"
export YABRIDGE_BIN="$YABRIDGE_HOME"
export PATH="$FIXTURE_BIN:\$PATH"
export LD_LIBRARY_PATH="$BATS_TEST_TMPDIR/lib"
export WINEDEBUG=-all
EOF

  cat > "$FIXTURE_BIN/fake-daw" <<EOF
#!/bin/bash
{
  if [[ -f "$LAUNCHER_MANIFEST" ]]; then
    printf 'manifest=present\n'
  else
    printf 'manifest=absent\n'
  fi
  printf 'WINEDEBUG=%s\n' "\${WINEDEBUG-<unset>}"
  printf 'WINEPREFIX=%s\n' "\${WINEPREFIX-<unset>}"
} > "$DAW_ENV_FILE"
exit "\${FAKE_DAW_EXIT_STATUS:-0}"
EOF
  write_version_command "$FIXTURE_BIN/wine" "$FIXTURE_WINE_VERSION_STRING"
  printf '#!/bin/bash\nexit 0\n' > "$FIXTURE_BIN/wineserver"
  # /tmp has no reflink support, so the fixture drops --reflink=always.
  cat > "$FIXTURE_BIN/cp" <<'EOF'
#!/bin/bash
set -euo pipefail
source_path="${@: -2:1}"
destination="${@: -1}"
/bin/cp -a "$source_path" "$destination"
EOF
  cat > "$YABRIDGE_HOME/yabridgectl" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "$YABRIDGECTL_CALLS"
if [[ "${1:-}" == sync ]]; then
  mkdir -p "$HOME/.vst/yabridge" "$HOME/.vst3/yabridge" "$HOME/.clap/yabridge"
  printf '%s\n' 'native' > "$HOME/.vst/yabridge/Good.so"
  ln -s "$MANIFEST_TEST_CLONE/Good.dll" "$HOME/.vst/yabridge/Good.dll"
fi
EOF
  chmod +x "$FIXTURE_BIN/fake-daw" "$FIXTURE_BIN/wineserver" \
    "$FIXTURE_BIN/cp" "$YABRIDGE_HOME/yabridgectl"
  write_fake_bwrap "$FIXTURE_BIN/bwrap"

  export HOME="$PRODUCTION_HOME"
  export PATH="$FIXTURE_BIN:$PATH"
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$TMPDIR"
  export SANDBOX_TEST_BWRAP_CALLS="$BWRAP_CALLS"
  export MANIFEST_TEST_CLONE="$COPY"
  export YABRIDGECTL_CALLS="$CALLS"
  unset DISPLAY WAYLAND_DISPLAY XAUTHORITY WINEDEBUG
}

run_launcher() {
  run "$FIXTURE_ROOT/daw-env.sh" "$@"
}

launcher_manifest() {
  MANIFEST_DESTINATION="$LAUNCHER_MANIFEST"
  manifest_text "$1"
}

launcher_manifest_json() {
  MANIFEST_DESTINATION="$LAUNCHER_MANIFEST"
  manifest_json "$1"
}

# The capability preflight runs bwrap too, so probe invocations are filtered out
# before asserting on the launch command.
launched_argv() {
  grep -v -e '/usr/bin/true$' -e '/bin/true$' "$BWRAP_CALLS" || true
}

# ── Staged inputs ────────────────────────────────────────────────────────────
#
# Everything the launcher proves before a manifest may be written: a validated
# clone with provenance, an isolated bridge tree, the component state setup.sh
# recorded, and the exact executables the run used. The base directory is a
# parameter so the same fixture can be staged under a hostile name.

load_run_manifest() {
  # shellcheck source=/dev/null
  source "$PROJECT_ROOT/lib/component-state.sh"
  # shellcheck source=/dev/null
  source "$PROJECT_ROOT/lib/run-manifest.sh"
}

make_prefix() {
  local path="$1"
  mkdir -p "$path/drive_c"
  printf '%s\n' 'WINE REGISTRY Version 2' > "$path/system.reg"
  printf '%s\n' 'plugin' > "$path/Good.dll"
}

write_provenance() {
  local clone="$1"
  local source="$2"
  local device inode
  read -r device inode <<< "$(stat -Lc '%d %i' -- "$source")"
  printf '%s\n%s\n%s\n' "$source" "$device" "$inode" \
    > "$clone/.yabridge-staging-source"
}

stage_manifest_inputs() {
  local base="$1"
  local bin="$base/bin"

  MANIFEST_BASE="$base"
  MANIFEST_SOURCE="$base/source"
  MANIFEST_CLONE="$base/clone"
  MANIFEST_ISOLATION="$base/isolation"
  MANIFEST_BRIDGE_HOME="$MANIFEST_ISOLATION/home"
  MANIFEST_DESTINATION="$MANIFEST_ISOLATION/run-manifest.json"
  MANIFEST_STATE="$base/build/component-state.env"
  MANIFEST_WINE="$bin/wine"
  MANIFEST_YABRIDGE_HOME="$base/build/yabridge"
  MANIFEST_YABRIDGECTL="$MANIFEST_YABRIDGE_HOME/yabridgectl"
  MANIFEST_DAW="$bin/fake-daw"
  MANIFEST_BWRAP="$bin/bwrap"

  mkdir -p "$bin" "$MANIFEST_YABRIDGE_HOME" \
    "$MANIFEST_BRIDGE_HOME/.vst/yabridge" \
    "$MANIFEST_BRIDGE_HOME/.vst3/yabridge" \
    "$MANIFEST_BRIDGE_HOME/.clap/yabridge"
  make_prefix "$MANIFEST_SOURCE"
  make_prefix "$MANIFEST_CLONE"
  write_provenance "$MANIFEST_CLONE" "$MANIFEST_SOURCE"
  seed_component_state_file "$MANIFEST_STATE"
  write_version_command "$MANIFEST_WINE" "$FIXTURE_WINE_VERSION_STRING"
  printf '#!/bin/bash\nexit 0\n' > "$MANIFEST_YABRIDGECTL"
  printf '#!/bin/bash\nexit 0\n' > "$MANIFEST_DAW"
  printf '#!/bin/bash\nexit 0\n' > "$MANIFEST_BWRAP"
  chmod +x "$MANIFEST_YABRIDGECTL" "$MANIFEST_DAW" "$MANIFEST_BWRAP"

  configure_manifest
}

configure_manifest() {
  RUN_MANIFEST_SOURCE="$MANIFEST_SOURCE"
  RUN_MANIFEST_CLONE="$MANIFEST_CLONE"
  RUN_MANIFEST_CLONE_IDENTITY="$(stat -c '%d %i' -- "$MANIFEST_CLONE")"
  RUN_MANIFEST_STATE_FILE="$MANIFEST_STATE"
  RUN_MANIFEST_WINE_EXECUTABLE="$MANIFEST_WINE"
  RUN_MANIFEST_YABRIDGE_HOME="$MANIFEST_YABRIDGE_HOME"
  RUN_MANIFEST_YABRIDGECTL="$MANIFEST_YABRIDGECTL"
  RUN_MANIFEST_BRIDGE_HOME="$MANIFEST_BRIDGE_HOME"
  RUN_MANIFEST_DAW="$MANIFEST_DAW"
  RUN_MANIFEST_BWRAP="$MANIFEST_BWRAP"
  RUN_MANIFEST_NAMESPACES_VERIFIED=true
  RUN_MANIFEST_UNSHARE_USER=true
  RUN_MANIFEST_NETWORK=false
  RUN_MANIFEST_QUIET_WINE=false
  RUN_MANIFEST_WINEDEBUG_SET=false
  RUN_MANIFEST_WINEDEBUG=""
  stage_manifest_command
}

# The shape of a command lib/sandbox.sh builds: bwrap first, namespace flags,
# mounts, then the resolved DAW after the argument separator.
stage_manifest_command() {
  MANIFEST_COMMAND=(
    "$MANIFEST_BWRAP"
    --unshare-pid --unshare-ipc --unshare-uts --unshare-cgroup-try
    --unshare-user --unshare-net --die-with-parent --new-session
    --ro-bind /usr /usr
    --bind "$MANIFEST_CLONE" "$MANIFEST_CLONE"
    --setenv HOME "$MANIFEST_BRIDGE_HOME"
    -- "$MANIFEST_DAW"
  )
}

write_manifest() {
  run write_run_manifest "$MANIFEST_DESTINATION" MANIFEST_COMMAND
}

# ── Reading the document back ────────────────────────────────────────────────

manifest_json() {
  python3 - "$MANIFEST_DESTINATION" "$1" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
for key in sys.argv[2].split("."):
    value = value[key]
print(json.dumps(value, ensure_ascii=False))
PY
}

manifest_text() {
  python3 - "$MANIFEST_DESTINATION" "$1" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
for key in sys.argv[2].split("."):
    value = value[key]
if not isinstance(value, str):
    raise SystemExit(f"{sys.argv[2]} is {type(value).__name__}, not a string")
print(value)
PY
}

# ── Schema, types and identity values ────────────────────────────────────────

@test "run manifest records exact executable identities" {
  load_run_manifest
  stage_manifest_inputs "$MANIFEST_TREE"

  write_manifest
  [ "$status" -eq 0 ]

  run python3 - "$MANIFEST_DESTINATION" <<'PY'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

assert data["schema_version"] == 1, data["schema_version"]
assert re.fullmatch(
    r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", data["generated_at"]
), data["generated_at"]
assert re.fullmatch(r"[0-9a-f]{40}", data["yabridge_commit"])
assert re.fullmatch(r"[0-9a-f]{64}", data["wine_sha256"])
assert isinstance(data["source_device"], int)
assert isinstance(data["source_inode"], int)
assert isinstance(data["clone_device"], int)
assert isinstance(data["clone_inode"], int)
assert isinstance(data["bridge_roots"], list)
assert len(data["bridge_roots"]) == 3
assert data["sandbox"]["enabled"] is True
assert data["sandbox"]["network"] is False
assert data["sandbox"]["namespace_mode"] == "user"
assert data["wine_diagnostics"]["quiet"] is False
assert data["wine_diagnostics"]["winedebug"] is None
for key in (
    "source_path",
    "clone_path",
    "wine_requested_version",
    "wine_installed_version",
    "wine_executable",
    "wine_version_string",
    "yabridge_requested_ref",
    "yabridge_home",
    "yabridgectl_path",
    "bridge_home",
    "daw_executable",
):
    assert isinstance(data[key], str) and data[key], key
assert isinstance(data["sandbox"]["bwrap"], str)
PY
  [ "$status" -eq 0 ]
}

@test "run manifest records the paths this run actually used" {
  load_run_manifest
  stage_manifest_inputs "$MANIFEST_TREE"

  write_manifest
  [ "$status" -eq 0 ]

  [ "$(manifest_text source_path)" = "$MANIFEST_SOURCE" ]
  [ "$(manifest_text clone_path)" = "$MANIFEST_CLONE" ]
  [ "$(manifest_text wine_executable)" = "$MANIFEST_WINE" ]
  [ "$(manifest_text wine_requested_version)" = "$FIXTURE_WINE_VERSION" ]
  [ "$(manifest_text wine_installed_version)" = "$FIXTURE_WINE_VERSION" ]
  [ "$(manifest_text wine_version_string)" = "$FIXTURE_WINE_VERSION_STRING" ]
  [ "$(manifest_text wine_sha256)" = "$FIXTURE_WINE_SHA256" ]
  [ "$(manifest_text yabridge_requested_ref)" = "$FIXTURE_YABRIDGE_REF" ]
  [ "$(manifest_text yabridge_commit)" = "$FIXTURE_YABRIDGE_COMMIT" ]
  [ "$(manifest_text yabridge_home)" = "$MANIFEST_YABRIDGE_HOME" ]
  [ "$(manifest_text yabridgectl_path)" = "$MANIFEST_YABRIDGECTL" ]
  [ "$(manifest_text bridge_home)" = "$MANIFEST_BRIDGE_HOME" ]
  [ "$(manifest_text daw_executable)" = "$MANIFEST_DAW" ]
  [ "$(manifest_text sandbox.bwrap)" = "$MANIFEST_BWRAP" ]
  [ "$(manifest_json bridge_roots)" = "$(printf '["%s", "%s", "%s"]' \
    "$MANIFEST_BRIDGE_HOME/.vst/yabridge" \
    "$MANIFEST_BRIDGE_HOME/.vst3/yabridge" \
    "$MANIFEST_BRIDGE_HOME/.clap/yabridge")" ]
}

@test "run manifest records the source identity from validated provenance" {
  load_run_manifest
  stage_manifest_inputs "$MANIFEST_TREE"
  local device inode
  read -r device inode <<< "$(stat -Lc '%d %i' -- "$MANIFEST_SOURCE")"

  write_manifest
  [ "$status" -eq 0 ]

  [ "$(manifest_json source_device)" = "$device" ]
  [ "$(manifest_json source_inode)" = "$inode" ]
  read -r device inode <<< "$(stat -c '%d %i' -- "$MANIFEST_CLONE")"
  [ "$(manifest_json clone_device)" = "$device" ]
  [ "$(manifest_json clone_inode)" = "$inode" ]
}

@test "the manifest bridge roots are the roots the bridge library generates" {
  load_run_manifest
  # shellcheck source=/dev/null
  source "$PROJECT_ROOT/lib/isolated-bridges.sh"

  [ "${RUN_MANIFEST_BRIDGE_RELATIVE_ROOTS[*]}" = \
    "${ISOLATED_BRIDGE_RELATIVE_ROOTS[*]}" ]
}

# ── JSON encoding is never shell string interpolation ────────────────────────

@test "run manifest encodes exotic paths and diagnostics exactly" {
  load_run_manifest
  stage_manifest_inputs "$BATS_TEST_TMPDIR/we ird \"quoted\" \\ pä th ✓"
  RUN_MANIFEST_WINEDEBUG_SET=true
  RUN_MANIFEST_WINEDEBUG='+relay,"warn+all",C:\\windows ✓'

  write_manifest
  [ "$status" -eq 0 ]

  [ "$(manifest_text source_path)" = "$MANIFEST_SOURCE" ]
  [ "$(manifest_text clone_path)" = "$MANIFEST_CLONE" ]
  [ "$(manifest_text daw_executable)" = "$MANIFEST_DAW" ]
  [ "$(manifest_text wine_diagnostics.winedebug)" = "$RUN_MANIFEST_WINEDEBUG" ]
  # Nothing the shell built ended up in the document: the encoder was handed
  # values, not JSON text.
  run grep -c 'pä th' "$MANIFEST_DESTINATION"
  [ "$status" -eq 0 ]
}

@test "run manifest refuses newlines in identity and diagnostic values" {
  load_run_manifest
  stage_manifest_inputs "$MANIFEST_TREE"
  RUN_MANIFEST_WINEDEBUG_SET=true
  RUN_MANIFEST_WINEDEBUG='-all
injected'

  write_manifest
  [ "$status" -ne 0 ]
  [[ "$output" == *"newline"* ]]
  [ ! -e "$MANIFEST_DESTINATION" ]

  configure_manifest
  run write_run_manifest "$MANIFEST_ISOLATION/run
manifest.json" MANIFEST_COMMAND
  [ "$status" -ne 0 ]
  [[ "$output" == *"newline"* ]]
}

# ── Component state is read, never evaluated ─────────────────────────────────

@test "run manifest never evaluates component state" {
  load_run_manifest
  stage_manifest_inputs "$MANIFEST_TREE"
  {
    printf 'WINE_VERSION=$(touch %s/injected-version)\n' "$MANIFEST_BASE"
    printf 'WINE_SHA256=`touch %s/injected-digest`\n' "$MANIFEST_BASE"
    printf 'YABRIDGE_REF=master; touch %s/injected-ref\n' "$MANIFEST_BASE"
    printf 'YABRIDGE_COMMIT=$(id > %s/injected-commit)\n' "$MANIFEST_BASE"
  } > "$MANIFEST_STATE"

  write_manifest

  [ "$status" -ne 0 ]
  [[ "$output" == *"component state"* ]]
  [ ! -e "$MANIFEST_DESTINATION" ]
  [ ! -e "$MANIFEST_BASE/injected-version" ]
  [ ! -e "$MANIFEST_BASE/injected-digest" ]
  [ ! -e "$MANIFEST_BASE/injected-ref" ]
  [ ! -e "$MANIFEST_BASE/injected-commit" ]
}

@test "run manifest refuses missing and malformed component state" {
  load_run_manifest
  stage_manifest_inputs "$MANIFEST_TREE"
  rm -f "$MANIFEST_STATE"

  write_manifest
  [ "$status" -ne 0 ]
  [[ "$output" == *"component state"* ]]

  configure_manifest
  printf 'WINE_VERSION=%s\nWINE_SHA256=%s\nYABRIDGE_REF=%s\nYABRIDGE_COMMIT=%s\n' \
    "$FIXTURE_WINE_VERSION" "$FIXTURE_WINE_SHA256" "$FIXTURE_YABRIDGE_REF" \
    "48ea9749b682c48875366134a42073d6b3d0a8c" > "$MANIFEST_STATE"
  write_manifest
  [ "$status" -ne 0 ]
  [[ "$output" == *"YABRIDGE_COMMIT"* ]]

  configure_manifest
  printf 'WINE_VERSION=%s\nYABRIDGE_REF=%s\nYABRIDGE_COMMIT=%s\n' \
    "$FIXTURE_WINE_VERSION" "$FIXTURE_YABRIDGE_REF" \
    "$FIXTURE_YABRIDGE_COMMIT" > "$MANIFEST_STATE"
  write_manifest
  [ "$status" -ne 0 ]
  [[ "$output" == *"WINE_SHA256"* ]]
  [ ! -e "$MANIFEST_DESTINATION" ]
}

@test "run manifest refuses a symlinked component state file" {
  load_run_manifest
  stage_manifest_inputs "$MANIFEST_TREE"
  mv "$MANIFEST_STATE" "$MANIFEST_BASE/elsewhere-state.env"
  ln -s "$MANIFEST_BASE/elsewhere-state.env" "$MANIFEST_STATE"

  write_manifest

  [ "$status" -ne 0 ]
  [[ "$output" == *"symlink"* ]]
  [ ! -e "$MANIFEST_DESTINATION" ]
}

# ── Provenance and identity are revalidated, not trusted ─────────────────────

@test "run manifest refuses provenance that no longer matches the source" {
  load_run_manifest
  stage_manifest_inputs "$MANIFEST_TREE"
  local device
  read -r device _ <<< "$(stat -Lc '%d %i' -- "$MANIFEST_SOURCE")"
  printf '%s\n%s\n%s\n' "$MANIFEST_SOURCE" "$device" 999999999 \
    > "$MANIFEST_CLONE/.yabridge-staging-source"

  write_manifest

  [ "$status" -ne 0 ]
  [[ "$output" == *"no longer the one this clone was made from"* ]]
  [ ! -e "$MANIFEST_DESTINATION" ]
}

# Not being able to read the source is not evidence that the source changed.
# Reporting the second when only the first happened sends the reader after a
# clone that is fine.
@test "run manifest separates an unreadable source identity from a mismatch" {
  load_run_manifest
  stage_manifest_inputs "$MANIFEST_TREE"

  PATH="$(shadow_failing_command stat):$PATH" write_manifest

  [ "$status" -ne 0 ]
  [[ "$output" == *"could not read the source prefix identity"* ]]
  [[ "$output" != *"no longer the one this clone was made from"* ]]
  [ ! -e "$MANIFEST_DESTINATION" ]
}

@test "run manifest reports a clone identity it cannot read" {
  load_run_manifest
  stage_manifest_inputs "$MANIFEST_TREE"
  local original_path="$PATH"

  PATH="$(shadow_failing_command stat):$PATH"
  run run_manifest_verify_clone_identity "$MANIFEST_CLONE"
  PATH="$original_path"

  [ "$status" -ne 0 ]
  [[ "$output" == *"could not read the prefix clone identity"* ]]
  [[ "$output" != *"changed after it was validated"* ]]
}

@test "run manifest refuses provenance naming a different source path" {
  load_run_manifest
  stage_manifest_inputs "$MANIFEST_TREE"
  make_prefix "$MANIFEST_BASE/other-source"
  write_provenance "$MANIFEST_CLONE" "$MANIFEST_BASE/other-source"

  write_manifest

  [ "$status" -ne 0 ]
  [[ "$output" == *"source"* ]]
  [ ! -e "$MANIFEST_DESTINATION" ]
}

@test "run manifest refuses missing and malformed provenance" {
  load_run_manifest
  stage_manifest_inputs "$MANIFEST_TREE"
  rm -f "$MANIFEST_CLONE/.yabridge-staging-source"

  write_manifest
  [ "$status" -ne 0 ]
  [[ "$output" == *"provenance"* ]]

  configure_manifest
  printf '%s\n' "$MANIFEST_SOURCE" > "$MANIFEST_CLONE/.yabridge-staging-source"
  write_manifest
  [ "$status" -ne 0 ]
  [[ "$output" == *"provenance"* ]]

  configure_manifest
  printf '%s\nnot-a-device\nnot-an-inode\n' "$MANIFEST_SOURCE" \
    > "$MANIFEST_CLONE/.yabridge-staging-source"
  write_manifest
  [ "$status" -ne 0 ]
  [[ "$output" == *"provenance"* ]]
  [ ! -e "$MANIFEST_DESTINATION" ]
}

@test "run manifest refuses a symlinked provenance record" {
  load_run_manifest
  stage_manifest_inputs "$MANIFEST_TREE"
  cp "$MANIFEST_CLONE/.yabridge-staging-source" "$MANIFEST_BASE/foreign-source"
  rm -f "$MANIFEST_CLONE/.yabridge-staging-source"
  ln -s "$MANIFEST_BASE/foreign-source" \
    "$MANIFEST_CLONE/.yabridge-staging-source"

  write_manifest

  [ "$status" -ne 0 ]
  [[ "$output" == *"provenance"* ]]
  [ ! -e "$MANIFEST_DESTINATION" ]
}

@test "run manifest refuses a clone that changed after validation" {
  load_run_manifest
  stage_manifest_inputs "$MANIFEST_TREE"
  rm -rf "$MANIFEST_CLONE"
  make_prefix "$MANIFEST_CLONE"
  write_provenance "$MANIFEST_CLONE" "$MANIFEST_SOURCE"

  write_manifest

  [ "$status" -ne 0 ]
  [[ "$output" == *"clone"* ]]
  [ ! -e "$MANIFEST_DESTINATION" ]
}

@test "run manifest refuses an unvalidated clone identity" {
  load_run_manifest
  stage_manifest_inputs "$MANIFEST_TREE"
  RUN_MANIFEST_CLONE_IDENTITY=""

  write_manifest

  [ "$status" -ne 0 ]
  [[ "$output" == *"clone"* ]]
  [ ! -e "$MANIFEST_DESTINATION" ]
}

@test "run manifest refuses symlinked source, clone and bridge inputs" {
  load_run_manifest
  local aliased
  for aliased in source clone bridge; do
    rm -rf "$MANIFEST_TREE"
    stage_manifest_inputs "$MANIFEST_TREE"
    case "$aliased" in
      source)
        mv "$MANIFEST_SOURCE" "$MANIFEST_BASE/real-source"
        ln -s "$MANIFEST_BASE/real-source" "$MANIFEST_SOURCE"
        ;;
      clone)
        mv "$MANIFEST_CLONE" "$MANIFEST_BASE/real-clone"
        ln -s "$MANIFEST_BASE/real-clone" "$MANIFEST_CLONE"
        RUN_MANIFEST_CLONE_IDENTITY="$(stat -c '%d %i' -- "$MANIFEST_CLONE")"
        ;;
      bridge)
        mkdir -p "$MANIFEST_BASE/real-bridge/.vst/yabridge" \
          "$MANIFEST_BASE/real-bridge/.vst3/yabridge" \
          "$MANIFEST_BASE/real-bridge/.clap/yabridge"
        rm -rf "$MANIFEST_BRIDGE_HOME"
        ln -s "$MANIFEST_BASE/real-bridge" "$MANIFEST_BRIDGE_HOME"
        ;;
    esac

    write_manifest
    [ "$status" -ne 0 ]
    [[ "$output" == *"symlink"* ]]
    [ ! -e "$MANIFEST_DESTINATION" ]
  done
}

@test "run manifest refuses a bridge root outside the isolated home" {
  load_run_manifest
  stage_manifest_inputs "$MANIFEST_TREE"
  mkdir -p "$MANIFEST_BASE/outside/yabridge"
  rm -rf "$MANIFEST_BRIDGE_HOME/.vst"
  ln -s "$MANIFEST_BASE/outside" "$MANIFEST_BRIDGE_HOME/.vst"

  write_manifest

  [ "$status" -ne 0 ]
  [[ "$output" == *"bridge root"* ]]
  [ ! -e "$MANIFEST_DESTINATION" ]
}

@test "run manifest refuses a swapped or missing Wine executable" {
  load_run_manifest
  stage_manifest_inputs "$MANIFEST_TREE"
  write_version_command "$MANIFEST_WINE" 'wine-9.21'

  write_manifest
  [ "$status" -ne 0 ]
  [[ "$output" == *"9.21"* ]]

  configure_manifest
  rm -f "$MANIFEST_WINE"
  write_manifest
  [ "$status" -ne 0 ]
  [[ "$output" == *"Wine"* ]]
  [ ! -e "$MANIFEST_DESTINATION" ]
}

@test "run manifest refuses missing yabridge and DAW executables" {
  load_run_manifest
  stage_manifest_inputs "$MANIFEST_TREE"
  rm -f "$MANIFEST_YABRIDGECTL"

  write_manifest
  [ "$status" -ne 0 ]
  [[ "$output" == *"yabridgectl"* ]]

  printf '#!/bin/bash\nexit 0\n' > "$MANIFEST_YABRIDGECTL"
  chmod +x "$MANIFEST_YABRIDGECTL"
  configure_manifest
  chmod -x "$MANIFEST_DAW"
  write_manifest
  [ "$status" -ne 0 ]
  [[ "$output" == *"DAW"* ]]
  [ ! -e "$MANIFEST_DESTINATION" ]
}

# ── The manifest matches the command that will actually run ──────────────────

@test "run manifest refuses a command that is not the verified sandbox" {
  load_run_manifest
  stage_manifest_inputs "$MANIFEST_TREE"
  MANIFEST_COMMAND=("$MANIFEST_DAW" --unshare-net -- "$MANIFEST_DAW")

  write_manifest
  [ "$status" -ne 0 ]
  [[ "$output" == *"bwrap"* ]]

  configure_manifest
  MANIFEST_COMMAND=("$MANIFEST_DAW")
  write_manifest
  [ "$status" -ne 0 ]
  [[ "$output" == *"empty"* ]]

  configure_manifest
  MANIFEST_COMMAND=("$MANIFEST_BWRAP" --unshare-user --unshare-net "$MANIFEST_DAW")
  write_manifest
  [ "$status" -ne 0 ]
  [[ "$output" == *"separator"* ]]

  configure_manifest
  MANIFEST_COMMAND=(
    "$MANIFEST_BWRAP" --unshare-user --unshare-net -- "$MANIFEST_WINE"
  )
  write_manifest
  [ "$status" -ne 0 ]
  [[ "$output" == *"DAW"* ]]
  [ ! -e "$MANIFEST_DESTINATION" ]
}

@test "run manifest refuses a network policy the command does not enforce" {
  load_run_manifest
  stage_manifest_inputs "$MANIFEST_TREE"
  MANIFEST_COMMAND=(
    "$MANIFEST_BWRAP" --unshare-user -- "$MANIFEST_DAW"
  )

  write_manifest
  [ "$status" -ne 0 ]
  [[ "$output" == *"network"* ]]

  configure_manifest
  RUN_MANIFEST_NETWORK=true
  write_manifest
  [ "$status" -ne 0 ]
  [[ "$output" == *"network"* ]]
  [ ! -e "$MANIFEST_DESTINATION" ]
}

@test "run manifest refuses a namespace mode the command does not use" {
  load_run_manifest
  stage_manifest_inputs "$MANIFEST_TREE"
  MANIFEST_COMMAND=(
    "$MANIFEST_BWRAP" --unshare-net -- "$MANIFEST_DAW"
  )

  write_manifest

  [ "$status" -ne 0 ]
  [[ "$output" == *"namespace"* ]]
  [ ! -e "$MANIFEST_DESTINATION" ]
}

@test "run manifest refuses to claim a sandbox that was never verified" {
  load_run_manifest
  stage_manifest_inputs "$MANIFEST_TREE"
  RUN_MANIFEST_NAMESPACES_VERIFIED=false

  write_manifest

  [ "$status" -ne 0 ]
  [[ "$output" == *"verif"* ]]
  [ ! -e "$MANIFEST_DESTINATION" ]
}

@test "run manifest records the setuid namespace mode without a user namespace" {
  load_run_manifest
  stage_manifest_inputs "$MANIFEST_TREE"
  RUN_MANIFEST_UNSHARE_USER=false
  MANIFEST_COMMAND=(
    "$MANIFEST_BWRAP" --unshare-pid --unshare-net -- "$MANIFEST_DAW"
  )

  write_manifest
  [ "$status" -eq 0 ]

  [ "$(manifest_text sandbox.namespace_mode)" = "setuid" ]
  [ "$(manifest_json sandbox.enabled)" = "true" ]
}

@test "run manifest records host networking only when the command shares it" {
  load_run_manifest
  stage_manifest_inputs "$MANIFEST_TREE"
  RUN_MANIFEST_NETWORK=true
  MANIFEST_COMMAND=(
    "$MANIFEST_BWRAP" --unshare-user --unshare-pid -- "$MANIFEST_DAW"
  )

  write_manifest
  [ "$status" -eq 0 ]

  [ "$(manifest_json sandbox.network)" = "true" ]
}

@test "run manifest refuses an argument array name it could shadow" {
  load_run_manifest
  stage_manifest_inputs "$MANIFEST_TREE"

  run write_run_manifest "$MANIFEST_DESTINATION" __run_manifest_command
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid"* ]]

  run write_run_manifest "$MANIFEST_DESTINATION" 'MANIFEST_COMMAND; touch pwned'
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid"* ]]
  [ ! -e "$MANIFEST_DESTINATION" ]
  [ ! -e pwned ]
}

# ── Quiet Wine is a decision, not an inherited value ─────────────────────────

@test "run manifest records an inherited WINEDEBUG without claiming the option" {
  load_run_manifest
  stage_manifest_inputs "$MANIFEST_TREE"
  RUN_MANIFEST_WINEDEBUG_SET=true
  RUN_MANIFEST_WINEDEBUG="-all"

  write_manifest
  [ "$status" -eq 0 ]

  [ "$(manifest_json wine_diagnostics.quiet)" = "false" ]
  [ "$(manifest_text wine_diagnostics.winedebug)" = "-all" ]
}

@test "run manifest records quiet Wine only with a matching WINEDEBUG" {
  load_run_manifest
  stage_manifest_inputs "$MANIFEST_TREE"
  RUN_MANIFEST_QUIET_WINE=true

  write_manifest
  [ "$status" -ne 0 ]
  [[ "$output" == *"WINEDEBUG"* ]]

  configure_manifest
  RUN_MANIFEST_QUIET_WINE=true
  RUN_MANIFEST_WINEDEBUG_SET=true
  RUN_MANIFEST_WINEDEBUG="-all"
  write_manifest
  [ "$status" -eq 0 ]
  [ "$(manifest_json wine_diagnostics.quiet)" = "true" ]
  [ "$(manifest_text wine_diagnostics.winedebug)" = "-all" ]
}

@test "run manifest refuses non-boolean policy values" {
  load_run_manifest
  stage_manifest_inputs "$MANIFEST_TREE"
  RUN_MANIFEST_NETWORK="yes"

  write_manifest

  [ "$status" -ne 0 ]
  [[ "$output" == *"true or false"* ]]
  [ ! -e "$MANIFEST_DESTINATION" ]
}

# ── Atomic replacement, private temporaries, hostile destinations ────────────

@test "a failed encoder preserves the previous complete manifest" {
  load_run_manifest
  stage_manifest_inputs "$MANIFEST_TREE"
  write_manifest
  [ "$status" -eq 0 ]
  local before
  before="$(sha256sum < "$MANIFEST_DESTINATION")"
  printf '%s\n' 'foreign' > "$MANIFEST_ISOLATION/.run-manifest.foreign"

  configure_manifest
  PATH="$(shadow_failing_command python3):$PATH" write_manifest

  [ "$status" -ne 0 ]
  [[ "$output" == *"encode"* ]]
  [ "$(sha256sum < "$MANIFEST_DESTINATION")" = "$before" ]
  [ -f "$MANIFEST_ISOLATION/.run-manifest.foreign" ]
  [ "$(find "$MANIFEST_ISOLATION" -maxdepth 1 -name '.run-manifest.*' |
    wc -l)" -eq 1 ]
}

# Cleanup runs on the failure path, and a sibling temporary is exactly the kind
# of name an attacker can create first. Removing one by pattern would follow a
# symlink out of the isolation directory.
@test "a failed write never follows a temporary it does not own" {
  load_run_manifest
  stage_manifest_inputs "$MANIFEST_TREE"
  printf '%s\n' 'private' > "$MANIFEST_BASE/outside-secret"
  ln -s "$MANIFEST_BASE/outside-secret" \
    "$MANIFEST_ISOLATION/.run-manifest.decoy"

  PATH="$(shadow_failing_command python3):$PATH" write_manifest

  [ "$status" -ne 0 ]
  [ -L "$MANIFEST_ISOLATION/.run-manifest.decoy" ]
  [ "$(cat "$MANIFEST_BASE/outside-secret")" = "private" ]
  # Only the decoy is left: this invocation cleaned up after itself.
  [ "$(find "$MANIFEST_ISOLATION" -maxdepth 1 -name '.run-manifest.*' |
    wc -l)" -eq 1 ]
}

@test "a failed rename preserves the previous complete manifest" {
  load_run_manifest
  stage_manifest_inputs "$MANIFEST_TREE"
  write_manifest
  [ "$status" -eq 0 ]
  local before
  before="$(sha256sum < "$MANIFEST_DESTINATION")"

  configure_manifest
  PATH="$(shadow_failing_command mv):$PATH" write_manifest

  [ "$status" -ne 0 ]
  [[ "$output" == *"replace"* ]]
  [ "$(sha256sum < "$MANIFEST_DESTINATION")" = "$before" ]
  [ "$(find "$MANIFEST_ISOLATION" -maxdepth 1 -name '.run-manifest.*' |
    wc -l)" -eq 0 ]
}

@test "run manifest refuses a symlinked destination" {
  load_run_manifest
  stage_manifest_inputs "$MANIFEST_TREE"
  printf '%s\n' 'not a manifest' > "$MANIFEST_BASE/outside-target.json"
  ln -s "$MANIFEST_BASE/outside-target.json" "$MANIFEST_DESTINATION"

  write_manifest

  [ "$status" -ne 0 ]
  [[ "$output" == *"symlink"* ]]
  [ "$(cat "$MANIFEST_BASE/outside-target.json")" = "not a manifest" ]
  # Refusing is only half an answer: whoever hits this has a launcher that will
  # not start until they deal with the file, so the way out has to be printed
  # with the refusal.
  [[ "$output" == *"ls -l -- "* ]]
  [[ "$output" == *"rm -- "* ]]
  [[ "$output" == *"$MANIFEST_DESTINATION"* ]]
}

# Every refusal from this library is one of several kinds of `Error:` line a
# launch can print, and the reader has to be able to tell which phase spoke.
# README documents this exact shape.
@test "run manifest refusals say the run manifest refused" {
  load_run_manifest
  stage_manifest_inputs "$MANIFEST_TREE"
  rm -f "$MANIFEST_STATE"

  write_manifest

  [ "$status" -ne 0 ]
  [[ "$output" == *"Error: run manifest: "* ]]
  [[ "$output" == *"component state"* ]]
}

@test "run manifest refuses a destination that is not a regular file" {
  load_run_manifest
  stage_manifest_inputs "$MANIFEST_TREE"
  mkdir -p "$MANIFEST_DESTINATION"

  write_manifest

  [ "$status" -ne 0 ]
  [[ "$output" == *"regular file"* ]]
  [ -d "$MANIFEST_DESTINATION" ]
}

@test "run manifest refuses a destination directory it cannot prove" {
  load_run_manifest
  stage_manifest_inputs "$MANIFEST_TREE"

  run write_run_manifest "$MANIFEST_BASE/absent/run-manifest.json" \
    MANIFEST_COMMAND
  [ "$status" -ne 0 ]
  [[ "$output" == *"directory"* ]]

  run write_run_manifest "isolation/run-manifest.json" MANIFEST_COMMAND
  [ "$status" -ne 0 ]
  [[ "$output" == *"absolute"* ]]

  ln -s "$MANIFEST_ISOLATION" "$MANIFEST_BASE/isolation-link"
  run write_run_manifest "$MANIFEST_BASE/isolation-link/run-manifest.json" \
    MANIFEST_COMMAND
  [ "$status" -ne 0 ]
  [[ "$output" == *"symlink"* ]]

  run write_run_manifest "$MANIFEST_ISOLATION/manifest.json" MANIFEST_COMMAND
  [ "$status" -ne 0 ]
  [[ "$output" == *"named run-manifest.json"* ]]
  [ ! -e "$MANIFEST_DESTINATION" ]
}

@test "a replaced manifest is complete and never a partial document" {
  load_run_manifest
  stage_manifest_inputs "$MANIFEST_TREE"
  write_manifest
  [ "$status" -eq 0 ]
  local first
  first="$(manifest_json generated_at)"

  configure_manifest
  RUN_MANIFEST_NETWORK=true
  MANIFEST_COMMAND=(
    "$MANIFEST_BWRAP" --unshare-user --unshare-pid -- "$MANIFEST_DAW"
  )
  write_manifest
  [ "$status" -eq 0 ]

  [ "$(manifest_json sandbox.network)" = "true" ]
  [ -n "$first" ]
  # A single JSON document, not an appended one.
  [ "$(grep -c '"schema_version"' "$MANIFEST_DESTINATION")" -eq 1 ]
  [ "$(find "$MANIFEST_ISOLATION" -maxdepth 1 -name '.run-manifest.*' |
    wc -l)" -eq 0 ]
}

# ── The launcher records the run it is about to start ────────────────────────

@test "launcher records the manifest before the DAW is executed" {
  stage_launcher_fixture

  run_launcher --prefix "$REAL_PREFIX" fake-daw

  [ "$status" -eq 0 ]
  [ -f "$DAW_ENV_FILE" ]
  # Only the DAW can write this line, and it saw a complete manifest already in
  # place, so provenance is recorded before anything of the run can change it.
  [ "$(daw_env_value manifest)" = "present" ]
  [ -f "$LAUNCHER_MANIFEST" ]
  [ "$(launcher_manifest source_path)" = "$REAL_PREFIX" ]
  [ "$(launcher_manifest clone_path)" = "$COPY" ]
  [ "$(launcher_manifest bridge_home)" = "$ISOLATED_HOME" ]
  [ "$(launcher_manifest daw_executable)" = "$FIXTURE_BIN/fake-daw" ]
  [ "$(launcher_manifest wine_executable)" = "$FIXTURE_BIN/wine" ]
  [ "$(launcher_manifest yabridgectl_path)" = "$YABRIDGE_HOME/yabridgectl" ]
  [ "$(launcher_manifest wine_sha256)" = "$FIXTURE_WINE_SHA256" ]
  [ "$(launcher_manifest yabridge_commit)" = "$FIXTURE_YABRIDGE_COMMIT" ]
  [ "$(launcher_manifest sandbox.bwrap)" = "$FIXTURE_BIN/bwrap" ]
  [ "$(launcher_manifest_json sandbox.enabled)" = "true" ]
  [ "$(launcher_manifest_json sandbox.network)" = "false" ]
  [[ "$(launched_argv)" == *" -- $FIXTURE_BIN/fake-daw"* ]]
  [[ "$output" == *"manifest:"* ]]
}

# A generated environment reached through a symlinked parent, and a yabridge
# home that is itself a symlink, are both perfectly usable. The run records the
# objects they name instead of refusing the names it was given — and it does not
# refuse them at all.
@test "a launch through noncanonical components records canonical identities" {
  stage_launcher_fixture
  local wine_canonical yabridge_canonical
  wine_canonical="$(realpath -e -- "$FIXTURE_BIN/wine")"
  yabridge_canonical="$(realpath -e -- "$YABRIDGE_HOME")"
  ln -s "$FIXTURE_BIN" "$BATS_TEST_TMPDIR/bin-link"
  ln -s "$YABRIDGE_HOME" "$BATS_TEST_TMPDIR/yabridge-link"
  cat > "$FIXTURE_ROOT/env.sh" <<EOF
export WINELOADER="$BATS_TEST_TMPDIR/bin-link/wine"
export WINESERVER="$FIXTURE_BIN/wineserver"
export WINEDLLPATH="$BATS_TEST_TMPDIR/winedll"
export YABRIDGE_BIN="$BATS_TEST_TMPDIR/yabridge-link"
export PATH="$FIXTURE_BIN:\$PATH"
export LD_LIBRARY_PATH="$BATS_TEST_TMPDIR/lib"
EOF

  run_launcher --prefix "$REAL_PREFIX" fake-daw

  [ "$status" -eq 0 ]
  [ "$(daw_env_value manifest)" = "present" ]
  [ "$(launcher_manifest wine_executable)" = "$wine_canonical" ]
  [ "$(launcher_manifest yabridge_home)" = "$yabridge_canonical" ]
  [ "$(launcher_manifest yabridgectl_path)" = "$yabridge_canonical/yabridgectl" ]
}

# yabridgectl installed by a package manager is commonly a symlink into a
# versioned directory. That is an identity to resolve, not a reason to stop a
# launch after the clone and the bridges have already been built.
@test "a PATH-resolved symlinked yabridgectl records its canonical executable" {
  stage_launcher_fixture
  local tools="$BATS_TEST_TMPDIR/tools"
  mkdir -p "$tools"
  mv "$YABRIDGE_HOME/yabridgectl" "$tools/yabridgectl"
  ln -s "$tools/yabridgectl" "$FIXTURE_BIN/yabridgectl"

  run_launcher --prefix "$REAL_PREFIX" fake-daw

  [ "$status" -eq 0 ]
  [ "$(daw_env_value manifest)" = "present" ]
  [ "$(launcher_manifest yabridgectl_path)" = "$(realpath -e -- "$tools/yabridgectl")" ]
}

@test "launcher records the source identity the clone was made from" {
  stage_launcher_fixture
  local device inode
  read -r device inode <<< "$(stat -Lc '%d %i' -- "$REAL_PREFIX")"

  run_launcher --prefix "$REAL_PREFIX" fake-daw

  [ "$status" -eq 0 ]
  [ "$(launcher_manifest_json source_device)" = "$device" ]
  [ "$(launcher_manifest_json source_inode)" = "$inode" ]
  read -r device inode <<< "$(stat -c '%d %i' -- "$COPY")"
  [ "$(launcher_manifest_json clone_device)" = "$device" ]
  [ "$(launcher_manifest_json clone_inode)" = "$inode" ]
}

@test "a manifest that cannot be recorded prevents the launch" {
  stage_launcher_fixture
  rm -f "$STATE_FILE"

  run_launcher --prefix "$REAL_PREFIX" fake-daw

  [ "$status" -ne 0 ]
  [[ "$output" == *"component state"* ]]
  [ ! -e "$DAW_ENV_FILE" ]
  [ ! -e "$LAUNCHER_MANIFEST" ]
  [ "$(launched_argv)" = "" ]
  # Whether the components were ever recorded is knowable before anything is
  # created, so the refusal costs the user neither a clone nor a bridge sync.
  [ ! -e "$COPY" ]
  [ ! -e "$ISOLATION" ]
  refute compgen -G "$FIXTURE_ROOT/prefix-copy.new.*"
  # yabridgectl writes this log the first time it runs, so its absence is proof
  # no bridge sync was attempted.
  [ ! -e "$CALLS" ]
}

# The generated environment is what names the components a run records, and
# whether it exists is knowable before anything is created — a project that was
# never set up should not be told so only after it has been cloned.
@test "a missing generated environment is refused before anything is cloned" {
  stage_launcher_fixture
  rm -f "$FIXTURE_ROOT/env.sh"

  run_launcher --prefix "$REAL_PREFIX" fake-daw

  [ "$status" -ne 0 ]
  [[ "$output" == *"env.sh"* ]]
  [[ "$output" == *"setup.sh"* ]]
  [ ! -e "$COPY" ]
  [ ! -e "$ISOLATION" ]
  [ ! -e "$DAW_ENV_FILE" ]
}

@test "a failed manifest keeps the manifest an earlier run recorded" {
  stage_launcher_fixture
  run_launcher --prefix "$REAL_PREFIX" fake-daw
  [ "$status" -eq 0 ]
  local before
  before="$(sha256sum < "$LAUNCHER_MANIFEST")"
  rm -f "$DAW_ENV_FILE"
  printf 'WINE_VERSION=11.8\n' > "$STATE_FILE"

  run_launcher --prefix "$REAL_PREFIX" fake-daw

  [ "$status" -ne 0 ]
  [ ! -e "$DAW_ENV_FILE" ]
  [ "$(sha256sum < "$LAUNCHER_MANIFEST")" = "$before" ]
  [ "$(find "$ISOLATION" -maxdepth 1 -name '.run-manifest.*' | wc -l)" -eq 0 ]
}

# The manifest re-reads the finished bwrap argv without knowing how many values
# each bwrap option takes. That scan is only sound while no option *value* can
# be read as a policy flag or as the argument separator, so the property is
# pinned here for the command the launcher really builds, with every
# path-carrying option in play.
@test "no sandbox option value can be mistaken for a policy flag or separator" {
  stage_launcher_fixture
  mkdir -p "$BATS_TEST_TMPDIR/writable" "$BATS_TEST_TMPDIR/native-plugins"

  run_launcher --writable-path "$BATS_TEST_TMPDIR/writable" \
    --native-plugin-path "$BATS_TEST_TMPDIR/native-plugins" \
    --prefix "$REAL_PREFIX" fake-daw

  [ "$status" -eq 0 ]
  local tokens
  tokens="$(tr ' ' '\n' <<< "$(launched_argv)")"
  # One separator, and the policy flags appear only where the launcher put them.
  [ "$(grep -cx -e '--' <<< "$tokens")" -eq 1 ]
  [ "$(grep -cx -e '--unshare-net' <<< "$tokens")" -eq 1 ]
  [ "$(grep -cx -e '--unshare-user' <<< "$tokens")" -le 1 ]
}

@test "launcher records the network policy the sandbox command enforces" {
  stage_launcher_fixture

  run_launcher --prefix "$REAL_PREFIX" fake-daw
  [ "$status" -eq 0 ]
  [ "$(launcher_manifest_json sandbox.network)" = "false" ]
  [[ "$(launched_argv)" == *" --unshare-net "* ]]

  : > "$BWRAP_CALLS"
  run_launcher --network --prefix "$REAL_PREFIX" fake-daw
  [ "$status" -eq 0 ]
  [ "$(launcher_manifest_json sandbox.network)" = "true" ]
  [[ "$(launched_argv)" != *" --unshare-net "* ]]
}

# An exported value in the launching shell is not a decision the user made on
# this command line, and the manifest must not report it as one.
@test "inherited policy variables cannot forge what the manifest records" {
  stage_launcher_fixture
  export SANDBOX_NETWORK=true
  export RUN_MANIFEST_NETWORK=true
  export RUN_MANIFEST_QUIET_WINE=true
  export RUN_MANIFEST_WINEDEBUG_SET=true
  export RUN_MANIFEST_WINEDEBUG=-all
  export QUIET_WINE=true

  run_launcher --prefix "$REAL_PREFIX" fake-daw

  [ "$status" -eq 0 ]
  [ "$(launcher_manifest_json sandbox.network)" = "false" ]
  [ "$(launcher_manifest_json wine_diagnostics.quiet)" = "false" ]
  [ "$(launcher_manifest_json wine_diagnostics.winedebug)" = "null" ]
  [[ "$(launched_argv)" == *" --unshare-net "* ]]
  [ "$(daw_env_value WINEDEBUG)" = "<unset>" ]
}

# ── Wine diagnostics ─────────────────────────────────────────────────────────

@test "the DAW keeps Wine diagnostics by default" {
  stage_launcher_fixture

  run_launcher --prefix "$REAL_PREFIX" fake-daw

  [ "$status" -eq 0 ]
  # The generated environment silences Wine; the launcher undoes that instead
  # of passing an invented value on to the DAW.
  [ "$(daw_env_value WINEDEBUG)" = "<unset>" ]
  [ "$(launcher_manifest_json wine_diagnostics.quiet)" = "false" ]
  [ "$(launcher_manifest_json wine_diagnostics.winedebug)" = "null" ]
}

@test "an inherited WINEDEBUG survives a default launch exactly" {
  stage_launcher_fixture
  export WINEDEBUG='+relay,warn+all'

  run_launcher --prefix "$REAL_PREFIX" fake-daw

  [ "$status" -eq 0 ]
  [ "$(daw_env_value WINEDEBUG)" = '+relay,warn+all' ]
  [ "$(launcher_manifest wine_diagnostics.winedebug)" = '+relay,warn+all' ]
  [ "$(launcher_manifest_json wine_diagnostics.quiet)" = "false" ]
}

@test "an inherited WINEDEBUG of -all is not the quiet option" {
  stage_launcher_fixture
  export WINEDEBUG=-all

  run_launcher --prefix "$REAL_PREFIX" fake-daw

  [ "$status" -eq 0 ]
  [ "$(daw_env_value WINEDEBUG)" = "-all" ]
  [ "$(launcher_manifest wine_diagnostics.winedebug)" = "-all" ]
  [ "$(launcher_manifest_json wine_diagnostics.quiet)" = "false" ]
}

@test "only --quiet-wine silences Wine for the DAW" {
  stage_launcher_fixture

  run_launcher --quiet-wine --prefix "$REAL_PREFIX" fake-daw

  [ "$status" -eq 0 ]
  [ "$(daw_env_value WINEDEBUG)" = "-all" ]
  [ "$(launcher_manifest_json wine_diagnostics.quiet)" = "true" ]
  [ "$(launcher_manifest wine_diagnostics.winedebug)" = "-all" ]
}

@test "--quiet-wine overrides an inherited diagnostics request" {
  stage_launcher_fixture
  export WINEDEBUG='+relay'

  run_launcher --quiet-wine --prefix "$REAL_PREFIX" fake-daw

  [ "$status" -eq 0 ]
  [ "$(daw_env_value WINEDEBUG)" = "-all" ]
  [ "$(launcher_manifest_json wine_diagnostics.quiet)" = "true" ]
}

@test "launcher documents the quiet Wine option" {
  stage_launcher_fixture

  run_launcher --help

  [ "$status" -eq 0 ]
  [[ "$output" == *"--quiet-wine"* ]]
}
