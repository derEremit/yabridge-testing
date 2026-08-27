#!/usr/bin/env bats

load test_helper

setup() {
  FIXTURE_ROOT="$BATS_TEST_TMPDIR/project"
  FIXTURE_BIN="$BATS_TEST_TMPDIR/bin"
  SOURCE="$BATS_TEST_TMPDIR/source"
  OUTSIDE="$BATS_TEST_TMPDIR/outside"
  COPY="$FIXTURE_ROOT/prefix-copy"
  YABRIDGE_HOME="$FIXTURE_ROOT/build/yabridge"
  FAKE_YABRIDGECTL="$YABRIDGE_HOME/yabridgectl"
  CALLS="$BATS_TEST_TMPDIR/yabridgectl.calls"
  ENV_LOG="$BATS_TEST_TMPDIR/yabridgectl.env"
  CP_CALLS="$BATS_TEST_TMPDIR/cp.calls"
  DAW_ENV_FILE="$BATS_TEST_TMPDIR/daw-env.out"
  ISOLATION="$FIXTURE_ROOT/isolation"
  ISOLATED_HOME="$ISOLATION/home"
  PRODUCTION_HOME="$BATS_TEST_TMPDIR/production-home"

  mkdir -p "$FIXTURE_ROOT/lib" "$FIXTURE_BIN" "$YABRIDGE_HOME" "$OUTSIDE" \
    "$PRODUCTION_HOME"
  printf '%s\n' 'evil' > "$OUTSIDE/Evil.dll"
  printf '%s\n' 'evil' > "$OUTSIDE/Evil.clap"
  mkdir -p "$OUTSIDE/Evil.vst3"
  printf '%s\n' 'evil' > "$OUTSIDE/Evil.vst3/module"
  printf '%s\n' 'chainloader' > "$YABRIDGE_HOME/libyabridge-chainloader-vst2.so"

  cp "$PROJECT_ROOT/daw-env.sh" "$FIXTURE_ROOT/daw-env.sh"
  chmod +x "$FIXTURE_ROOT/daw-env.sh"
  copy_launcher_libraries "$FIXTURE_ROOT/lib"
  # A launch records the components it used, so the identities setup.sh writes
  # are part of a working fixture project.
  seed_component_state_file "$FIXTURE_ROOT/build/component-state.env"

  cat > "$FIXTURE_ROOT/env.sh" <<EOF
export WINELOADER="$FIXTURE_BIN/wine"
export WINESERVER="$FIXTURE_BIN/wineserver"
export WINEDLLPATH="$BATS_TEST_TMPDIR/winedll"
export YABRIDGE_BIN="$YABRIDGE_HOME"
export PATH="$FIXTURE_BIN:\$PATH"
export LD_LIBRARY_PATH="$BATS_TEST_TMPDIR/lib"
EOF

  cat > "$FIXTURE_BIN/fake-daw" <<EOF
#!/bin/bash
{
  printf 'WINEPREFIX=%s\n' "\${WINEPREFIX-<unset>}"
  printf 'VST_PATH=%s\n' "\${VST_PATH-<unset>}"
  printf 'VST3_PATH=%s\n' "\${VST3_PATH-<unset>}"
  printf 'CLAP_PATH=%s\n' "\${CLAP_PATH-<unset>}"
} > "$DAW_ENV_FILE"
EOF
  cat > "$FIXTURE_BIN/wine" <<'EOF'
#!/bin/bash
printf '%s\n' 'wine-11.8'
EOF
  cat > "$FIXTURE_BIN/wineserver" <<'EOF'
#!/bin/bash
exit 0
EOF
  cat > "$FIXTURE_BIN/cp" <<'EOF'
#!/bin/bash
set -euo pipefail
source_path="${@: -2:1}"
destination="${@: -1}"
printf '%s\n' 'clone' >> "$DAW_TEST_CP_CALLS"
/bin/cp -a "$source_path" "$destination"
EOF
  cat > "$FAKE_YABRIDGECTL" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "$YABRIDGECTL_CALLS"
{
  printf 'call=%s\n' "${1:-}"
  printf 'HOME=%s\n' "${HOME-<unset>}"
  printf 'XDG_CONFIG_HOME=%s\n' "${XDG_CONFIG_HOME-<unset>}"
  printf 'XDG_DATA_HOME=%s\n' "${XDG_DATA_HOME-<unset>}"
} >> "$YABRIDGECTL_ENV"
if [[ "${1:-}" == set ]]; then
  # Packaged yabridgectl 5.1.1 (and the current master clap `path_auto`
  # definition without SetTrue/SetFalse) panics on any `set` invocation.
  echo "fake yabridgectl: set panicked on path_auto" >&2
  exit 101
fi
if [[ "${1:-}" == add ]]; then
  # Each walk root is logged on its own line so a path that merely prefixes
  # another (the clone root vs drive_c/Program Files) cannot hide as a match.
  for add_root in "${@:2}"; do
    printf 'add-root=%s\n' "$add_root" >> "$YABRIDGECTL_CALLS"
  done
fi
if [[ "${1:-}" == sync ]]; then
  if [[ "${YABRIDGECTL_FAIL_SYNC:-false}" == true ]]; then
    echo "fake yabridgectl: sync failed" >&2
    exit 1
  fi
  if [[ -n "${YABRIDGECTL_SYNC_HOOK:-}" ]]; then
    # shellcheck source=/dev/null
    source "$YABRIDGECTL_SYNC_HOOK"
  fi
fi
EOF
  chmod +x "$FIXTURE_BIN/fake-daw" "$FIXTURE_BIN/wine" \
    "$FIXTURE_BIN/wineserver" "$FIXTURE_BIN/cp" "$FAKE_YABRIDGECTL"

  # Bridge generation is what this suite covers, so the sandbox is stubbed: the
  # fake bwrap records its argv, applies the environment it was told to set, and
  # runs the command it was given. Real Bubblewrap enforcement is covered by
  # tests/sandbox.bats.
  write_fake_bwrap "$FIXTURE_BIN/bwrap"
  export SANDBOX_TEST_BWRAP_CALLS="$BATS_TEST_TMPDIR/bwrap.calls"
  export HOME="$PRODUCTION_HOME"

  export TMPDIR="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$TMPDIR"
  export YABRIDGECTL_CALLS="$CALLS"
  export YABRIDGECTL_ENV="$ENV_LOG"
  export DAW_TEST_CP_CALLS="$CP_CALLS"
  export PATH="$FIXTURE_BIN:$PATH"
  export BRIDGE_TEST_COPY="$COPY"
  export BRIDGE_TEST_OUTSIDE="$OUTSIDE"
  export BRIDGE_TEST_YABRIDGE_HOME="$YABRIDGE_HOME"
  make_prefix "$SOURCE"
}

make_prefix() {
  local path="$1"
  mkdir -p "$path/Good.vst3"
  printf '%s\n' 'WINE REGISTRY Version 2' > "$path/system.reg"
  printf '%s\n' 'plugin' > "$path/Good.dll"
  printf '%s\n' 'plugin' > "$path/Good.clap"
  printf '%s\n' 'plugin' > "$path/Good.vst3/module"
}

load_isolated_bridges() {
  # shellcheck source=/dev/null
  source "$PROJECT_ROOT/lib/isolated-bridges.sh"
}

write_sync_hook() {
  cat > "$BATS_TEST_TMPDIR/sync-hook.sh"
  export YABRIDGECTL_SYNC_HOOK="$BATS_TEST_TMPDIR/sync-hook.sh"
}

good_sync_hook() {
  write_sync_hook <<'HOOK'
mkdir -p "$HOME/.vst/yabridge" "$HOME/.clap/yabridge" \
  "$HOME/.vst3/yabridge/Good.vst3/Contents/x86_64-linux" \
  "$HOME/.vst3/yabridge/Good.vst3/Contents/x86_64-win"
printf '%s\n' 'native' > "$HOME/.vst/yabridge/Good.so"
ln -s "$BRIDGE_TEST_COPY/Good.dll" "$HOME/.vst/yabridge/Good.dll"
printf '%s\n' 'native' > "$HOME/.clap/yabridge/Good.clap"
ln -s "$BRIDGE_TEST_COPY/Good.clap" "$HOME/.clap/yabridge/Good.clap-win"
printf '%s\n' 'native' \
  > "$HOME/.vst3/yabridge/Good.vst3/Contents/x86_64-linux/Good.so"
ln -s "$BRIDGE_TEST_COPY/Good.vst3" \
  "$HOME/.vst3/yabridge/Good.vst3/Contents/x86_64-win/Good.vst3"
HOOK
}

empty_sync_hook() {
  write_sync_hook <<'HOOK'
mkdir -p "$HOME/.vst/yabridge" "$HOME/.vst3/yabridge" "$HOME/.clap/yabridge"
HOOK
}

prepare_clone_fixture() {
  make_prefix "$COPY"
}

# A Wine-shaped clone: plugin trees live under drive_c, and dosdevices/z: plus
# the user Documents folder point outside the clone the way a real prefix does.
prepare_wine_clone_fixture() {
  local z_target="${1:-$PRODUCTION_HOME}"

  make_prefix "$COPY"
  mkdir -p "$COPY/drive_c/Program Files/VstPlugins" \
    "$COPY/drive_c/Program Files/Common Files/VST3" \
    "$COPY/drive_c/Program Files/Common Files/CLAP" \
    "$COPY/drive_c/Program Files (x86)/VstPlugins" \
    "$COPY/drive_c/users/wineuser" \
    "$COPY/dosdevices" \
    "$PRODUCTION_HOME/Documents"
  printf '%s\n' 'plugin' \
    > "$COPY/drive_c/Program Files/VstPlugins/Good.dll"
  printf '%s\n' 'plugin' \
    > "$COPY/drive_c/Program Files/Common Files/CLAP/Good.clap"
  mkdir -p "$COPY/drive_c/Program Files/Common Files/VST3/Good.vst3"
  printf '%s\n' 'plugin' \
    > "$COPY/drive_c/Program Files/Common Files/VST3/Good.vst3/module"
  ln -s ../drive_c "$COPY/dosdevices/c:"
  ln -s "$z_target" "$COPY/dosdevices/z:"
  ln -s "$PRODUCTION_HOME/Documents" \
    "$COPY/drive_c/users/wineuser/Documents"
}

run_prepare() {
  run prepare_isolated_bridges \
    "$FIXTURE_ROOT" "$COPY" "$FAKE_YABRIDGECTL" "$YABRIDGE_HOME"
}

run_daw_fixture() {
  run "$FIXTURE_ROOT/daw-env.sh" "$@"
}

sync_call_count() {
  if [[ ! -f "$CALLS" ]]; then
    printf '0\n'
    return 0
  fi
  grep -c '^sync' "$CALLS" || true
}

# ── Isolated yabridgectl invocation ──────────────────────────────────────────

@test "bridge generation runs yabridgectl with isolated HOME and XDG values" {
  load_isolated_bridges
  prepare_clone_fixture
  good_sync_hook

  run_prepare

  [ "$status" -eq 0 ]
  local logged_home
  logged_home="$(grep -m1 '^HOME=' "$ENV_LOG")"
  logged_home="${logged_home#HOME=}"
  [[ "$logged_home" == "$FIXTURE_ROOT/isolation"* ]]
  [[ "$logged_home" == */home ]]
  [ "$logged_home" != "$HOME" ]
  [[ "$logged_home" != "$HOME"/* ]]
  grep -Fxq "XDG_CONFIG_HOME=$logged_home/.config" "$ENV_LOG"
  grep -Fxq "XDG_DATA_HOME=$logged_home/.local/share" "$ENV_LOG"
}

@test "bridge sync receives only in-clone Windows plugin directories" {
  load_isolated_bridges
  prepare_wine_clone_fixture
  good_sync_hook

  run_prepare

  [ "$status" -eq 0 ]
  local copy_real
  copy_real="$(realpath -e -- "$COPY")"
  grep -Fxq "yabridge_home = '$(realpath -e -- "$YABRIDGE_HOME")'" \
    "$ISOLATED_HOME/.config/yabridgectl/config.toml"
  grep -Fxq "add-root=$copy_real/drive_c/Program Files" "$CALLS"
  grep -Fxq "add-root=$copy_real/drive_c/Program Files (x86)" "$CALLS"
  grep -Fxq "sync --force --prune" "$CALLS"
  [ "$(grep -c '^add ' "$CALLS")" -eq 1 ]
  refute grep -Fxq "add-root=$copy_real" "$CALLS"
  refute grep -Fxq "add $copy_real" "$CALLS"
  refute grep -Fq "$SOURCE" "$CALLS"
}

# Wine prefixes expose the host filesystem through dosdevices/z: (often / or
# $HOME) and through user-folder redirects such as Documents. Those paths must
# never become yabridgectl walk roots; adding the clone root would follow them.
@test "bridge generation does not add dosdevices or escaping host symlinks" {
  load_isolated_bridges
  prepare_wine_clone_fixture /
  good_sync_hook

  run_prepare

  [ "$status" -eq 0 ]
  local copy_real
  copy_real="$(realpath -e -- "$COPY")"
  grep -Fxq "add-root=$copy_real/drive_c/Program Files" "$CALLS"
  grep -Fxq "add-root=$copy_real/drive_c/Program Files (x86)" "$CALLS"
  refute grep -Fxq "add-root=$copy_real" "$CALLS"
  refute grep -Fxq "add-root=$copy_real/drive_c" "$CALLS"
  refute grep -Fxq "add-root=$copy_real/dosdevices" "$CALLS"
  refute grep -Fxq "add-root=$copy_real/dosdevices/z:" "$CALLS"
  refute grep -Fxq "add-root=/" "$CALLS"
  refute grep -Fxq "add-root=$PRODUCTION_HOME" "$CALLS"
  refute grep -Fq "dosdevices" "$CALLS"
  refute grep -F "add-root=$copy_real/drive_c/users" "$CALLS"
}

@test "bridge generation does not fall back to the clone root without plugin dirs" {
  load_isolated_bridges
  prepare_clone_fixture
  mkdir -p "$COPY/drive_c/users/wineuser" "$COPY/dosdevices"
  ln -s / "$COPY/dosdevices/z:"
  good_sync_hook

  run_prepare

  [ "$status" -eq 0 ]
  local copy_real
  copy_real="$(realpath -e -- "$COPY")"
  refute grep -E '^add-root=' "$CALLS"
  refute grep -Fxq "add $copy_real" "$CALLS"
  refute grep -Fxq "add-root=$copy_real/drive_c" "$CALLS"
}

@test "bridge generation refuses a Program Files symlink that escapes the clone" {
  load_isolated_bridges
  prepare_clone_fixture
  mkdir -p "$COPY/drive_c"
  ln -s "$PRODUCTION_HOME" "$COPY/drive_c/Program Files"
  good_sync_hook

  run_prepare

  [ "$status" -ne 0 ]
  [[ "$output" == *"escapes the clone Windows tree"* ]]
  [ ! -e "$ISOLATION" ]
  refute compgen -G "$FIXTURE_ROOT/isolation.new.*"
}

# Packaged yabridgectl 5.1.1 panics on `set` because clap `path_auto` is not a
# SetTrue/SetFalse flag. Isolated generation must never call that command.
@test "bridge generation never calls yabridgectl set" {
  load_isolated_bridges
  prepare_clone_fixture
  good_sync_hook

  run_prepare

  [ "$status" -eq 0 ]
  [ -L "$ISOLATED_HOME/.vst/yabridge/Good.dll" ]
  grep -Fxq "yabridge_home = '$(realpath -e -- "$YABRIDGE_HOME")'" \
    "$ISOLATED_HOME/.config/yabridgectl/config.toml"
  [ ! -e "$PRODUCTION_HOME/.config/yabridgectl/config.toml" ]
  refute grep -E '^set( |$)' "$CALLS"
}

@test "bridge generation accepts generated targets inside the clone" {
  load_isolated_bridges
  prepare_clone_fixture
  good_sync_hook

  run_prepare

  [ "$status" -eq 0 ]
  [ -L "$ISOLATED_HOME/.vst/yabridge/Good.dll" ]
  [ -L "$ISOLATED_HOME/.clap/yabridge/Good.clap-win" ]
  [ -L "$ISOLATED_HOME/.vst3/yabridge/Good.vst3/Contents/x86_64-win/Good.vst3" ]
  [ -f "$ISOLATION/.yabridge-staging-bridges" ]
  refute compgen -G "$FIXTURE_ROOT/isolation.new.*"
}

# ── Canonical fail-closed metadata validation ────────────────────────────────

@test "bridge validation rejects an absolute target outside the clone" {
  load_isolated_bridges
  prepare_clone_fixture
  write_sync_hook <<'HOOK'
mkdir -p "$HOME/.vst/yabridge"
printf '%s\n' 'native' > "$HOME/.vst/yabridge/Evil.so"
ln -s "$BRIDGE_TEST_OUTSIDE/Evil.dll" "$HOME/.vst/yabridge/Evil.dll"
HOOK

  run_prepare

  [ "$status" -ne 0 ]
  [[ "$output" == *"escapes the plugin clone"* ]]
  [ ! -e "$ISOLATION" ]
  refute compgen -G "$FIXTURE_ROOT/isolation.new.*"
  [ -f "$OUTSIDE/Evil.dll" ]
}

@test "bridge validation rejects a parent-traversing target" {
  load_isolated_bridges
  prepare_clone_fixture
  write_sync_hook <<'HOOK'
mkdir -p "$HOME/.vst/yabridge"
printf '%s\n' 'native' > "$HOME/.vst/yabridge/Evil.so"
ln -s "../../../../outside/Evil.dll" "$HOME/.vst/yabridge/Evil.dll"
HOOK

  run_prepare

  [ "$status" -ne 0 ]
  [[ "$output" == *"escapes the plugin clone"* || "$output" == *"does not resolve"* ]]
  [ ! -e "$ISOLATION" ]
  [ -f "$OUTSIDE/Evil.dll" ]
}

@test "bridge validation rejects a target that canonicalizes outside the clone" {
  load_isolated_bridges
  prepare_clone_fixture
  ln -s "$OUTSIDE/Evil.dll" "$COPY/Escape.dll"
  write_sync_hook <<'HOOK'
mkdir -p "$HOME/.vst/yabridge"
printf '%s\n' 'native' > "$HOME/.vst/yabridge/Escape.so"
ln -s "$BRIDGE_TEST_COPY/Escape.dll" "$HOME/.vst/yabridge/Escape.dll"
HOOK

  run_prepare

  [ "$status" -ne 0 ]
  [[ "$output" == *"escapes the plugin clone"* ]]
  [ ! -e "$ISOLATION" ]
  [ -f "$OUTSIDE/Evil.dll" ]
}

@test "bridge validation rejects metadata that is not a Windows plugin symlink" {
  load_isolated_bridges
  prepare_clone_fixture
  write_sync_hook <<'HOOK'
mkdir -p "$HOME/.vst/yabridge"
printf '%s\n' 'native' > "$HOME/.vst/yabridge/Fake.so"
printf '%s\n' 'not a symlink' > "$HOME/.vst/yabridge/Fake.dll"
HOOK

  run_prepare

  [ "$status" -ne 0 ]
  [[ "$output" == *"not a Windows plugin symlink"* ]]
  [ ! -e "$ISOLATION" ]
}

@test "bridge validation rejects unresolvable bridge metadata" {
  load_isolated_bridges
  prepare_clone_fixture
  write_sync_hook <<'HOOK'
mkdir -p "$HOME/.vst/yabridge"
printf '%s\n' 'native' > "$HOME/.vst/yabridge/Missing.so"
ln -s "$BRIDGE_TEST_COPY/Missing.dll" "$HOME/.vst/yabridge/Missing.dll"
HOOK

  run_prepare

  [ "$status" -ne 0 ]
  [[ "$output" == *"does not resolve"* ]]
  [ ! -e "$ISOLATION" ]
}

@test "bridge validation rejects a VST3 Windows module outside the clone" {
  load_isolated_bridges
  prepare_clone_fixture
  write_sync_hook <<'HOOK'
mkdir -p "$HOME/.vst3/yabridge/Evil.vst3/Contents/x86_64-linux" \
  "$HOME/.vst3/yabridge/Evil.vst3/Contents/x86_64-win"
printf '%s\n' 'native' \
  > "$HOME/.vst3/yabridge/Evil.vst3/Contents/x86_64-linux/Evil.so"
ln -s "$BRIDGE_TEST_OUTSIDE/Evil.vst3" \
  "$HOME/.vst3/yabridge/Evil.vst3/Contents/x86_64-win/Evil.vst3"
HOOK

  run_prepare

  [ "$status" -ne 0 ]
  [[ "$output" == *"escapes the plugin clone"* ]]
  [ ! -e "$ISOLATION" ]
  [ -f "$OUTSIDE/Evil.vst3/module" ]
}

@test "bridge validation rejects a CLAP Windows target outside the clone" {
  load_isolated_bridges
  prepare_clone_fixture
  write_sync_hook <<'HOOK'
mkdir -p "$HOME/.clap/yabridge"
printf '%s\n' 'native' > "$HOME/.clap/yabridge/Evil.clap"
ln -s "$BRIDGE_TEST_OUTSIDE/Evil.clap" "$HOME/.clap/yabridge/Evil.clap-win"
HOOK

  run_prepare

  [ "$status" -ne 0 ]
  [[ "$output" == *"escapes the plugin clone"* ]]
  [ ! -e "$ISOLATION" ]
  [ -f "$OUTSIDE/Evil.clap" ]
}

@test "bridge validation rejects a renamed vst3-win target outside the clone" {
  load_isolated_bridges
  prepare_clone_fixture
  write_sync_hook <<'HOOK'
mkdir -p "$HOME/.vst3/yabridge"
printf '%s\n' 'native' > "$HOME/.vst3/yabridge/Evil.so"
ln -s "$BRIDGE_TEST_OUTSIDE/Evil.vst3" "$HOME/.vst3/yabridge/Evil.vst3-win"
HOOK

  run_prepare

  [ "$status" -ne 0 ]
  [[ "$output" == *"escapes the plugin clone"* ]]
  [ ! -e "$ISOLATION" ]
}

@test "bridge validation rejects native bridge symlinks outside the clone" {
  load_isolated_bridges
  prepare_clone_fixture
  write_sync_hook <<'HOOK'
mkdir -p "$HOME/.vst/yabridge"
ln -s "$BRIDGE_TEST_OUTSIDE/Evil.dll" "$HOME/.vst/yabridge/Smuggled.so"
ln -s "$BRIDGE_TEST_COPY/Good.dll" "$HOME/.vst/yabridge/Smuggled.dll"
HOOK

  run_prepare

  [ "$status" -ne 0 ]
  [[ "$output" == *"points outside"* ]]
  [ ! -e "$ISOLATION" ]
}

@test "bridge validation rejects a symlinked isolated bridge root" {
  load_isolated_bridges
  prepare_clone_fixture
  write_sync_hook <<'HOOK'
mkdir -p "$HOME/.vst"
rm -rf "$HOME/.vst/yabridge"
ln -s "$BRIDGE_TEST_OUTSIDE" "$HOME/.vst/yabridge"
HOOK

  run_prepare

  [ "$status" -ne 0 ]
  [[ "$output" == *"bridge root is a symlink"* ]]
  [ ! -e "$ISOLATION" ]
  [ -f "$OUTSIDE/Evil.dll" ]
}

# A redirected intermediate component is worse than a redirected leaf: the
# bridges it holds can point at legitimate clone plugins, so nothing downstream
# notices that the directory handed to the DAW lives outside the isolated home.
@test "bridge validation rejects a symlinked intermediate bridge component" {
  load_isolated_bridges
  prepare_clone_fixture
  write_sync_hook <<'HOOK'
outside_vst="$BRIDGE_TEST_OUTSIDE/fake-vst"
mkdir -p "$outside_vst/yabridge"
printf '%s\n' 'native' > "$outside_vst/yabridge/Good.so"
ln -s "$BRIDGE_TEST_COPY/Good.dll" "$outside_vst/yabridge/Good.dll"
rm -rf "$HOME/.vst"
ln -s "$outside_vst" "$HOME/.vst"
HOOK

  run_prepare

  [ "$status" -ne 0 ]
  [[ "$output" == *"isolated bridge root is a symlink"* ]]
  [[ "$output" == *"/home/.vst"* ]]
  [[ "$output" != *"/home/.vst/yabridge"* ]]
  [ ! -e "$ISOLATION" ]
  refute compgen -G "$FIXTURE_ROOT/isolation.new.*"
}

@test "bridge validation fails closed when a bridge root cannot be traversed" {
  load_isolated_bridges
  prepare_clone_fixture
  good_sync_hook
  cat > "$FIXTURE_BIN/find" <<'EOF'
#!/bin/bash
if [[ "${1:-}" == */.vst/yabridge ]]; then
  printf 'find: %s: Permission denied\n' "$1" >&2
  exit 1
fi
exec /usr/bin/find "$@"
EOF
  chmod +x "$FIXTURE_BIN/find"

  run_prepare

  [ "$status" -ne 0 ]
  [[ "$output" == *"could not traverse the isolated bridge root"* ]]
  [ ! -e "$ISOLATION" ]
  refute compgen -G "$FIXTURE_ROOT/isolation.new.*"
  refute compgen -G "$TMPDIR/yabridge-bridge-scan.*"
}

@test "bridge validation classifies Windows metadata case-insensitively" {
  load_isolated_bridges
  prepare_clone_fixture
  write_sync_hook <<'HOOK'
mkdir -p "$HOME/.vst/yabridge"
printf '%s\n' 'native' > "$HOME/.vst/yabridge/Upper.so"
ln -s "$BRIDGE_TEST_OUTSIDE/Evil.dll" "$HOME/.vst/yabridge/Upper.DLL"
HOOK

  run_prepare

  [ "$status" -ne 0 ]
  [[ "$output" == *"escapes the plugin clone"* ]]
  [ ! -e "$ISOLATION" ]
}

@test "an uppercase Windows extension counts as generated bridge output" {
  load_isolated_bridges
  prepare_clone_fixture
  write_sync_hook <<'HOOK'
mkdir -p "$HOME/.vst/yabridge"
printf '%s\n' 'native' > "$HOME/.vst/yabridge/Upper.so"
ln -s "$BRIDGE_TEST_COPY/Good.dll" "$HOME/.vst/yabridge/Upper.DLL"
HOOK

  run_prepare

  [ "$status" -eq 0 ]
  [[ "$output" != *"no isolated yabridge bridges were generated"* ]]
  [ -L "$ISOLATED_HOME/.vst/yabridge/Upper.DLL" ]
}

@test "yabridgectl runs from a path containing an equals sign" {
  load_isolated_bridges
  prepare_clone_fixture
  good_sync_hook
  local equals_dir="$BATS_TEST_TMPDIR/ya=dir"
  mkdir -p "$equals_dir"
  cp "$FAKE_YABRIDGECTL" "$equals_dir/yabridgectl"
  chmod +x "$equals_dir/yabridgectl"

  run prepare_isolated_bridges \
    "$FIXTURE_ROOT" "$COPY" "$equals_dir/yabridgectl" "$YABRIDGE_HOME"

  [ "$status" -eq 0 ]
  grep -Fxq "sync --force --prune" "$CALLS"
  grep -Fxq "HOME=$FIXTURE_ROOT/isolation.new.$$/home" "$ENV_LOG"
  [ -L "$ISOLATED_HOME/.vst/yabridge/Good.dll" ]
}

@test "validate_bridge_targets rejects targets outside the clone directly" {
  load_isolated_bridges
  prepare_clone_fixture
  mkdir -p "$ISOLATED_HOME/.vst/yabridge"
  printf '%s\n' 'native' > "$ISOLATED_HOME/.vst/yabridge/Evil.so"
  ln -s "$OUTSIDE/Evil.dll" "$ISOLATED_HOME/.vst/yabridge/Evil.dll"

  run validate_bridge_targets "$ISOLATED_HOME" "$COPY"

  [ "$status" -ne 0 ]
}

@test "validate_bridge_targets accepts targets inside the clone directly" {
  load_isolated_bridges
  prepare_clone_fixture
  mkdir -p "$ISOLATED_HOME/.vst/yabridge"
  printf '%s\n' 'native' > "$ISOLATED_HOME/.vst/yabridge/Good.so"
  ln -s "$COPY/Good.dll" "$ISOLATED_HOME/.vst/yabridge/Good.dll"

  run validate_bridge_targets "$ISOLATED_HOME" "$COPY"

  [ "$status" -eq 0 ]
}

# ── Empty bridge output ──────────────────────────────────────────────────────

@test "empty bridge output fails closed" {
  load_isolated_bridges
  prepare_clone_fixture
  empty_sync_hook

  run_prepare

  [ "$status" -ne 0 ]
  [[ "$output" == *"no isolated yabridge bridges were generated"* ]]
  [ ! -e "$ISOLATION" ]
}

@test "empty bridge output is accepted only when allow-empty is explicit" {
  load_isolated_bridges
  prepare_clone_fixture
  empty_sync_hook
  ISOLATED_BRIDGES_ALLOW_EMPTY=true

  run_prepare

  [ "$status" -eq 0 ]
  [ -d "$ISOLATED_HOME/.vst/yabridge" ]
}

# ── Refresh independence and atomic activation ───────────────────────────────

@test "reuse of a valid bridge tree skips yabridgectl entirely" {
  load_isolated_bridges
  prepare_clone_fixture
  good_sync_hook
  run_prepare
  [ "$status" -eq 0 ]

  run_prepare

  [ "$status" -eq 0 ]
  [ "$(sync_call_count)" -eq 1 ]
}

@test "refresh regenerates the isolated bridge tree" {
  load_isolated_bridges
  prepare_clone_fixture
  good_sync_hook
  run_prepare
  [ "$status" -eq 0 ]
  printf '%s\n' 'stale' > "$ISOLATED_HOME/.vst/yabridge/stale-marker"
  ISOLATED_BRIDGES_REFRESH=true

  run_prepare

  [ "$status" -eq 0 ]
  [ "$(sync_call_count)" -eq 2 ]
  [ ! -e "$ISOLATED_HOME/.vst/yabridge/stale-marker" ]
  [ -L "$ISOLATED_HOME/.vst/yabridge/Good.dll" ]
  refute compgen -G "$FIXTURE_ROOT/isolation.new.*"
}

@test "failed refresh preserves the existing isolated bridge tree" {
  load_isolated_bridges
  prepare_clone_fixture
  good_sync_hook
  run_prepare
  [ "$status" -eq 0 ]
  printf '%s\n' 'keep me' > "$ISOLATED_HOME/.vst/yabridge/existing"
  ISOLATED_BRIDGES_REFRESH=true
  export YABRIDGECTL_FAIL_SYNC=true

  run_prepare

  [ "$status" -ne 0 ]
  [ "$(cat "$ISOLATED_HOME/.vst/yabridge/existing")" = "keep me" ]
  [ -f "$ISOLATION/.yabridge-staging-bridges" ]
  refute compgen -G "$FIXTURE_ROOT/isolation.new.*"
}

@test "stale reused bridge state names refresh-bridges as the recovery" {
  load_isolated_bridges
  prepare_clone_fixture
  good_sync_hook
  run_prepare
  [ "$status" -eq 0 ]
  rm -f "$COPY/Good.dll"

  run_prepare

  [ "$status" -ne 0 ]
  [[ "$output" == *"does not resolve"* ]]
  [[ "$output" == *"stale or unusable"* ]]
  [[ "$output" == *"Regenerate it with --refresh-bridges"* ]]
  [ "$(sync_call_count)" -eq 1 ]
}

@test "empty reused bridge state names refresh-bridges as the recovery" {
  load_isolated_bridges
  prepare_clone_fixture
  good_sync_hook
  run_prepare
  [ "$status" -eq 0 ]
  rm -rf "$ISOLATED_HOME/.vst/yabridge" "$ISOLATED_HOME/.vst3/yabridge" \
    "$ISOLATED_HOME/.clap/yabridge"
  mkdir -p "$ISOLATED_HOME/.vst/yabridge" "$ISOLATED_HOME/.vst3/yabridge" \
    "$ISOLATED_HOME/.clap/yabridge"

  run_prepare

  [ "$status" -ne 0 ]
  [[ "$output" == *"no isolated yabridge bridges were generated"* ]]
  [[ "$output" == *"stale or unusable"* ]]
  [[ "$output" == *"Regenerate it with --refresh-bridges"* ]]
}

@test "a freshly generated failure does not suggest refresh-bridges" {
  load_isolated_bridges
  prepare_clone_fixture
  empty_sync_hook

  run_prepare

  [ "$status" -ne 0 ]
  [[ "$output" == *"no isolated yabridge bridges were generated"* ]]
  [[ "$output" != *"stale or unusable"* ]]
}

@test "rejected refresh does not activate escaping bridge state" {
  load_isolated_bridges
  prepare_clone_fixture
  good_sync_hook
  run_prepare
  [ "$status" -eq 0 ]
  printf '%s\n' 'keep me' > "$ISOLATED_HOME/.vst/yabridge/existing"
  write_sync_hook <<'HOOK'
mkdir -p "$HOME/.vst/yabridge"
printf '%s\n' 'native' > "$HOME/.vst/yabridge/Evil.so"
ln -s "$BRIDGE_TEST_OUTSIDE/Evil.dll" "$HOME/.vst/yabridge/Evil.dll"
HOOK
  ISOLATED_BRIDGES_REFRESH=true

  run_prepare

  [ "$status" -ne 0 ]
  [[ "$output" == *"escapes the plugin clone"* ]]
  [ "$(cat "$ISOLATED_HOME/.vst/yabridge/existing")" = "keep me" ]
  [ ! -e "$ISOLATED_HOME/.vst/yabridge/Evil.dll" ]
  refute compgen -G "$FIXTURE_ROOT/isolation.new.*"
}

# ── Invocation-owned state and fail-closed cleanup ───────────────────────────

@test "an existing temporary bridge path fails closed as ambiguous" {
  load_isolated_bridges
  prepare_clone_fixture
  good_sync_hook
  mkdir -p "$FIXTURE_ROOT/isolation.new.$$"
  printf '%s\n' 'foreign' > "$FIXTURE_ROOT/isolation.new.$$/sentinel"

  run_prepare

  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing ambiguous cleanup"* ]]
  [ "$(cat "$FIXTURE_ROOT/isolation.new.$$/sentinel")" = "foreign" ]
  [ ! -e "$ISOLATION" ]
}

@test "cleanup leaves foreign temporary bridge paths untouched" {
  load_isolated_bridges
  prepare_clone_fixture
  good_sync_hook
  mkdir -p "$FIXTURE_ROOT/isolation.new.999999999"
  printf '%s\n' 'foreign' > "$FIXTURE_ROOT/isolation.new.999999999/sentinel"

  run_prepare

  [ "$status" -eq 0 ]
  [ "$(cat "$FIXTURE_ROOT/isolation.new.999999999/sentinel")" = "foreign" ]
}

@test "foreign isolated bridge state fails closed without deletion" {
  load_isolated_bridges
  prepare_clone_fixture
  good_sync_hook
  mkdir -p "$ISOLATION"
  printf '%s\n' 'foreign' > "$ISOLATION/sentinel"

  run_prepare

  [ "$status" -ne 0 ]
  [[ "$output" == *"foreign or incomplete"* ]]
  [ "$(cat "$ISOLATION/sentinel")" = "foreign" ]
  [ "$(sync_call_count)" -eq 0 ]
}

@test "a symlinked isolated bridge tree fails closed without touching its target" {
  load_isolated_bridges
  prepare_clone_fixture
  good_sync_hook
  mkdir -p "$OUTSIDE/bridge-target"
  printf '%s\n' 'do not touch' > "$OUTSIDE/bridge-target/sentinel"
  ln -s "$OUTSIDE/bridge-target" "$ISOLATION"

  run_prepare

  [ "$status" -ne 0 ]
  [[ "$output" == *"symlink"* ]]
  [ "$(cat "$OUTSIDE/bridge-target/sentinel")" = "do not touch" ]
  [ -L "$ISOLATION" ]
}

@test "a tampered bridge marker fails closed" {
  load_isolated_bridges
  prepare_clone_fixture
  good_sync_hook
  run_prepare
  [ "$status" -eq 0 ]
  printf '%s\n' 'yabridge-staging-bridges-v1' "$OUTSIDE" "$YABRIDGE_HOME" \
    > "$ISOLATION/.yabridge-staging-bridges"

  run_prepare

  [ "$status" -ne 0 ]
  [[ "$output" == *"foreign or incomplete"* ]]
  [ "$(sync_call_count)" -eq 1 ]
}

# ── Native plugin path validation ────────────────────────────────────────────

@test "native plugin path values reject relative and list-breaking input" {
  load_isolated_bridges
  mkdir -p "$BATS_TEST_TMPDIR/native"

  run validate_native_plugin_path "relative/path"
  [ "$status" -ne 0 ]

  run validate_native_plugin_path "$BATS_TEST_TMPDIR/native:$OUTSIDE"
  [ "$status" -ne 0 ]

  run validate_native_plugin_path "$BATS_TEST_TMPDIR/absent"
  [ "$status" -ne 0 ]

  run validate_native_plugin_path "$BATS_TEST_TMPDIR/native"
  [ "$status" -eq 0 ]
}

# ── DAW plugin environment ───────────────────────────────────────────────────

@test "launcher exposes only isolated bridge roots to the DAW" {
  good_sync_hook
  export VST_PATH="/nonexistent-production/.vst/yabridge"
  export VST3_PATH="/nonexistent-production/.vst3/yabridge"
  export CLAP_PATH="/nonexistent-production/.clap/yabridge"

  run_daw_fixture --prefix "$SOURCE" fake-daw

  [ "$status" -eq 0 ]
  [ "$(daw_env_value VST_PATH)" = "$ISOLATED_HOME/.vst/yabridge" ]
  [ "$(daw_env_value VST3_PATH)" = "$ISOLATED_HOME/.vst3/yabridge" ]
  [ "$(daw_env_value CLAP_PATH)" = "$ISOLATED_HOME/.clap/yabridge" ]
  refute grep -Fq 'nonexistent-production' "$DAW_ENV_FILE"
}

@test "launcher appends only explicitly supplied native plugin paths" {
  good_sync_hook
  mkdir -p "$BATS_TEST_TMPDIR/native-a" "$BATS_TEST_TMPDIR/native-b"

  run_daw_fixture --prefix "$SOURCE" \
    --native-plugin-path "$BATS_TEST_TMPDIR/native-a" \
    --native-plugin-path "$BATS_TEST_TMPDIR/native-b" \
    fake-daw

  [ "$status" -eq 0 ]
  [ "$(daw_env_value VST_PATH)" = \
    "$ISOLATED_HOME/.vst/yabridge:$BATS_TEST_TMPDIR/native-a:$BATS_TEST_TMPDIR/native-b" ]
  [ "$(daw_env_value VST3_PATH)" = \
    "$ISOLATED_HOME/.vst3/yabridge:$BATS_TEST_TMPDIR/native-a:$BATS_TEST_TMPDIR/native-b" ]
  [ "$(daw_env_value CLAP_PATH)" = \
    "$ISOLATED_HOME/.clap/yabridge:$BATS_TEST_TMPDIR/native-a:$BATS_TEST_TMPDIR/native-b" ]
}

# The plugin paths handed to the DAW are the whole point of the isolation: a
# production yabridge directory on VST_PATH would put production bridges back
# in front of the DAW no matter what the sandbox mounts say.
@test "a production yabridge directory can never reach VST_PATH" {
  good_sync_hook
  mkdir -p "$PRODUCTION_HOME/.vst/yabridge"
  printf '%s\n' 'production bridge' \
    > "$PRODUCTION_HOME/.vst/yabridge/Production.so"

  run_daw_fixture --prefix "$SOURCE" \
    --native-plugin-path "$PRODUCTION_HOME/.vst/yabridge" fake-daw

  [ "$status" -ne 0 ]
  [[ "$output" == *"protected"* ]]
  [ ! -e "$DAW_ENV_FILE" ]
  [ ! -e "$ISOLATION" ]
  [ "$(sync_call_count)" -eq 0 ]
}

@test "launcher rejects an option-looking native plugin path value" {
  run_daw_fixture --prefix "$SOURCE" --native-plugin-path --fresh fake-daw

  [ "$status" -eq 2 ]
  [[ "$output" == *"--native-plugin-path requires a value"* ]]
  [ ! -e "$DAW_ENV_FILE" ]
}

@test "launcher rejects a missing native plugin path value" {
  good_sync_hook

  run_daw_fixture --prefix "$SOURCE" --native-plugin-path

  [ "$status" -eq 2 ]
  [[ "$output" == *"Error: --native-plugin-path requires a value"* ]]
  [ ! -e "$ISOLATION" ]
  [ ! -e "$DAW_ENV_FILE" ]
  [ "$(sync_call_count)" -eq 0 ]
}

@test "launcher refreshes bridges without recloning the prefix" {
  good_sync_hook
  run_daw_fixture --prefix "$SOURCE" fake-daw
  [ "$status" -eq 0 ]

  run_daw_fixture --refresh-bridges --prefix "$SOURCE" fake-daw

  [ "$status" -eq 0 ]
  [ "$(wc -l < "$CP_CALLS")" -eq 1 ]
  [ "$(sync_call_count)" -eq 2 ]
}

@test "launcher reclones with fresh without regenerating bridges" {
  good_sync_hook
  run_daw_fixture --prefix "$SOURCE" fake-daw
  [ "$status" -eq 0 ]

  run_daw_fixture --fresh --prefix "$SOURCE" fake-daw

  [ "$status" -eq 0 ]
  [ "$(wc -l < "$CP_CALLS")" -eq 2 ]
  [ "$(sync_call_count)" -eq 1 ]
}

@test "launcher regenerates bridges with fresh only when refresh is explicit" {
  good_sync_hook
  run_daw_fixture --prefix "$SOURCE" fake-daw
  [ "$status" -eq 0 ]

  run_daw_fixture --fresh --refresh-bridges --prefix "$SOURCE" fake-daw

  [ "$status" -eq 0 ]
  [ "$(wc -l < "$CP_CALLS")" -eq 2 ]
  [ "$(sync_call_count)" -eq 2 ]
}

@test "launcher regenerates nothing when neither refresh flag is given" {
  good_sync_hook
  run_daw_fixture --prefix "$SOURCE" fake-daw
  [ "$status" -eq 0 ]

  run_daw_fixture --prefix "$SOURCE" fake-daw

  [ "$status" -eq 0 ]
  [ "$(wc -l < "$CP_CALLS")" -eq 1 ]
  [ "$(sync_call_count)" -eq 1 ]
}

@test "launcher refuses to start a DAW without generated bridges" {
  empty_sync_hook

  run_daw_fixture --prefix "$SOURCE" fake-daw

  [ "$status" -ne 0 ]
  [[ "$output" == *"no isolated yabridge bridges were generated"* ]]
  [ ! -e "$DAW_ENV_FILE" ]
}

@test "launcher allows empty bridge output only for explicit diagnostics" {
  empty_sync_hook

  run_daw_fixture --allow-empty --prefix "$SOURCE" fake-daw

  [ "$status" -eq 0 ]
  [ "$(daw_env_value VST_PATH)" = "$ISOLATED_HOME/.vst/yabridge" ]
}

@test "clean removes the isolated bridge tree that the launcher generated" {
  good_sync_hook
  run_daw_fixture --prefix "$SOURCE" fake-daw
  [ "$status" -eq 0 ]
  [ -d "$ISOLATION" ]

  run_daw_fixture --prefix "$SOURCE" --clean

  [ "$status" -eq 0 ]
  [ ! -e "$ISOLATION" ]
  [ ! -e "$COPY" ]
}
