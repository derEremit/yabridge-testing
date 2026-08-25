#!/usr/bin/env bats

load test_helper

setup() {
  FIXTURE_ROOT="$BATS_TEST_TMPDIR/project"
  FIXTURE_BIN="$BATS_TEST_TMPDIR/bin"
  PRODUCTION_HOME="$BATS_TEST_TMPDIR/production-home"
  REAL_PREFIX="$PRODUCTION_HOME/.audio-production/winplugins"
  COPY="$FIXTURE_ROOT/prefix-copy"
  ISOLATION="$FIXTURE_ROOT/isolation"
  ISOLATED_HOME="$ISOLATION/home"
  YABRIDGE_HOME="$FIXTURE_ROOT/build/yabridge"
  FAKE_YABRIDGECTL="$YABRIDGE_HOME/yabridgectl"
  RUNTIME="$BATS_TEST_TMPDIR/runtime"
  X11_DIR="$BATS_TEST_TMPDIR/x11"
  PROJECTS="$BATS_TEST_TMPDIR/projects"
  BWRAP_CALLS="$BATS_TEST_TMPDIR/bwrap.calls"
  CALLS="$BATS_TEST_TMPDIR/yabridgectl.calls"
  CP_CALLS="$BATS_TEST_TMPDIR/cp.calls"
  DAW_ENV_FILE="$BATS_TEST_TMPDIR/daw-env.out"
  RUNTIME_DESTINATION="/run/user/$(id -u)"

  mkdir -p "$FIXTURE_ROOT/lib" "$FIXTURE_BIN" "$YABRIDGE_HOME" "$RUNTIME" \
    "$X11_DIR" "$PROJECTS"
  printf '%s\n' 'chainloader' > "$YABRIDGE_HOME/libyabridge-chainloader-vst2.so"

  # A fake production home. No test ever reads or writes the real home.
  local plugin_root
  for plugin_root in .vst .vst3 .clap; do
    mkdir -p "$PRODUCTION_HOME/$plugin_root/yabridge"
    printf '%s\n' 'production bridge' \
      > "$PRODUCTION_HOME/$plugin_root/yabridge/Production.so"
  done
  make_prefix "$REAL_PREFIX"

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
  printf 'HOME=%s\n' "\${HOME-<unset>}"
  printf 'VST_PATH=%s\n' "\${VST_PATH-<unset>}"
  printf 'VST3_PATH=%s\n' "\${VST3_PATH-<unset>}"
  printf 'CLAP_PATH=%s\n' "\${CLAP_PATH-<unset>}"
  printf 'WINEPREFIX=%s\n' "\${WINEPREFIX-<unset>}"
  printf 'XDG_RUNTIME_DIR=%s\n' "\${XDG_RUNTIME_DIR-<unset>}"
  printf 'argv'
  printf ' %q' "\$@"
  printf '\n'
} > "$DAW_ENV_FILE"
exit "\${FAKE_DAW_EXIT_STATUS:-0}"
EOF
  cat > "$FIXTURE_BIN/suicidal-daw" <<'EOF'
#!/bin/bash
kill -TERM $$
sleep 5
EOF
  cat > "$FIXTURE_BIN/wine" <<'EOF'
#!/bin/bash
printf '%s\n' 'wine-11.8'
EOF
  cat > "$FIXTURE_BIN/wineserver" <<'EOF'
#!/bin/bash
exit 0
EOF
  # /tmp has no reflink support, so the fixture drops --reflink=always and
  # records that a clone was requested.
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
if [[ "${1:-}" == sync ]]; then
  mkdir -p "$HOME/.vst/yabridge" "$HOME/.vst3/yabridge" "$HOME/.clap/yabridge"
  printf '%s\n' 'native' > "$HOME/.vst/yabridge/Good.so"
  ln -s "$SANDBOX_TEST_CLONE/Good.dll" "$HOME/.vst/yabridge/Good.dll"
fi
EOF
  chmod +x "$FIXTURE_BIN/fake-daw" "$FIXTURE_BIN/suicidal-daw" \
    "$FIXTURE_BIN/wine" "$FIXTURE_BIN/wineserver" "$FIXTURE_BIN/cp" \
    "$FAKE_YABRIDGECTL"

  write_fake_bwrap "$FIXTURE_BIN/bwrap"

  export HOME="$PRODUCTION_HOME"
  export XDG_RUNTIME_DIR="$RUNTIME"
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$TMPDIR"
  export PATH="$FIXTURE_BIN:$PATH"
  export SANDBOX_TEST_BWRAP_CALLS="$BWRAP_CALLS"
  export SANDBOX_TEST_CLONE="$COPY"
  export YABRIDGECTL_CALLS="$CALLS"
  export DAW_TEST_CP_CALLS="$CP_CALLS"
  unset DISPLAY WAYLAND_DISPLAY XAUTHORITY
}

make_prefix() {
  local path="$1"
  mkdir -p "$path/drive_c"
  printf '%s\n' 'WINE REGISTRY Version 2' > "$path/system.reg"
  printf '%s\n' 'plugin' > "$path/Good.dll"
  printf '%s\n' 'production state' > "$path/drive_c/production.txt"
}

# ── Command construction harness ─────────────────────────────────────────────

load_sandbox() {
  # shellcheck source=/dev/null
  source "$PROJECT_ROOT/lib/sandbox.sh"
}

# Command construction is tested against a clone and isolation tree that the
# launcher would have produced; launcher tests generate them for real instead.
configure_sandbox() {
  make_prefix "$COPY"
  mkdir -p "$ISOLATED_HOME/.vst/yabridge" "$ISOLATED_HOME/.vst3/yabridge" \
    "$ISOLATED_HOME/.clap/yabridge"
  SANDBOX_PROJECT_ROOT="$FIXTURE_ROOT"
  SANDBOX_REAL_PREFIX="$REAL_PREFIX"
  SANDBOX_CLONE="$COPY"
  SANDBOX_ISOLATION="$ISOLATION"
  SANDBOX_ISOLATED_HOME="$ISOLATED_HOME"
  SANDBOX_X11_SOCKET_DIR="$X11_DIR"
  SANDBOX_DEVICE_PATHS=()
  SANDBOX_WRITABLE_PATHS=()
  SANDBOX_NATIVE_PLUGIN_PATHS=()
  SANDBOX_NETWORK=false
  require_bwrap
  assert_sandbox_namespaces
}

# Mirrors the launcher: the DAW is resolved by the preflight, and construction
# is handed the canonical result. Tests that target the construction guards
# themselves call build_bwrap_command directly instead.
build_command() {
  SANDBOX_COMMAND=()
  resolve_daw_executable "$1" || return 1
  build_bwrap_command SANDBOX_COMMAND "$@"
}

show_command() {
  printf 'argv:'
  printf ' %q' ${SANDBOX_COMMAND[@]+"${SANDBOX_COMMAND[@]}"}
  printf '\n'
}

argv_has_sequence() {
  local -a want=("$@")
  local total="${#SANDBOX_COMMAND[@]}"
  local wanted="${#want[@]}"
  local index offset

  for ((index = 0; index + wanted <= total; index++)); do
    for ((offset = 0; offset < wanted; offset++)); do
      [[ "${SANDBOX_COMMAND[index + offset]}" == "${want[offset]}" ]] || break
    done
    if [[ "$offset" -eq "$wanted" ]]; then
      return 0
    fi
  done
  return 1
}

assert_sequence() {
  argv_has_sequence "$@" && return 0
  printf 'missing argv sequence:'
  printf ' %q' "$@"
  printf '\n'
  show_command
  return 1
}

refute_sequence() {
  argv_has_sequence "$@" || return 0
  printf 'unexpected argv sequence:'
  printf ' %q' "$@"
  printf '\n'
  show_command
  return 1
}

# Reports the mount that actually governs a path: the last mount in argv order
# whose destination covers it. bwrap applies operations in order, so a narrow
# read-only bind placed after a broad writable mount is what the sandbox sees.
effective_mount() {
  local target="$1"
  local total="${#SANDBOX_COMMAND[@]}"
  local result=""
  local index flag mode destination

  for ((index = 0; index < total; index++)); do
    flag="${SANDBOX_COMMAND[index]}"
    case "$flag" in
      --) break ;;
      --ro-bind | --ro-bind-try)
        mode=ro
        destination="${SANDBOX_COMMAND[index + 2]}"
        ;;
      --bind | --bind-try | --dev-bind | --dev-bind-try)
        mode=rw
        destination="${SANDBOX_COMMAND[index + 2]}"
        ;;
      --tmpfs | --proc | --dev)
        mode=rw
        destination="${SANDBOX_COMMAND[index + 1]}"
        ;;
      *) continue ;;
    esac
    if [[ "$target" == "$destination" || "$target" == "$destination"/* ]]; then
      result="$mode $destination"
    fi
  done
  printf '%s\n' "$result"
}

assert_read_only() {
  local mount
  mount="$(effective_mount "$1")"
  [[ "$mount" == "ro "* ]] && return 0
  printf 'expected %q to be read-only, governing mount: %s\n' "$1" \
    "${mount:-<unmounted>}"
  show_command
  return 1
}

assert_writable() {
  local mount
  mount="$(effective_mount "$1")"
  [[ "$mount" == "rw "* ]] && return 0
  printf 'expected %q to be writable, governing mount: %s\n' "$1" \
    "${mount:-<unmounted>}"
  show_command
  return 1
}

# Fails when any bind exposes the given host path, either directly or through
# an ancestor. A path merely covered by the sandbox tmpfs is not exposed: the
# tmpfs replaces that location instead of sharing host content.
refute_exposed_source() {
  local target="$1"
  local total="${#SANDBOX_COMMAND[@]}"
  local index flag source

  for ((index = 0; index < total; index++)); do
    flag="${SANDBOX_COMMAND[index]}"
    case "$flag" in
      --) break ;;
      --ro-bind | --ro-bind-try | --bind | --bind-try | --dev-bind | \
        --dev-bind-try)
        source="${SANDBOX_COMMAND[index + 1]}"
        ;;
      *) continue ;;
    esac
    if [[ "$target" == "$source" || "$target" == "$source"/* ]]; then
      printf 'host path %q is exposed through %q\n' "$target" "$source"
      show_command
      return 1
    fi
  done
  return 0
}

run_daw_fixture() {
  run "$FIXTURE_ROOT/daw-env.sh" "$@"
}

# The capability preflight runs bwrap too, so probe invocations are filtered
# out before asserting on the launch command.
launched_argv() {
  grep -v -e '/usr/bin/true$' -e '/bin/true$' "$BWRAP_CALLS" || true
}

sync_call_count() {
  if [[ ! -f "$CALLS" ]]; then
    printf '0\n'
    return 0
  fi
  grep -c '^sync' "$CALLS" || true
}

# Everything a refused input must have left untouched. A rejected sandbox input
# has to cost nothing: no clone, no clone candidate, no provenance marker, no
# isolation tree, no bridge candidate, no yabridgectl sync and no DAW.
refute_launcher_mutation() {
  local leftovers
  [ ! -e "$DAW_ENV_FILE" ]
  [ ! -e "$COPY" ]
  [ ! -e "$COPY/.yabridge-staging-source" ]
  [ ! -e "$ISOLATION" ]
  [ "$(sync_call_count)" -eq 0 ]
  leftovers="$(find "$FIXTURE_ROOT" -maxdepth 1 \
    \( -name 'prefix-copy.new.*' -o -name 'isolation.new.*' \) 2>/dev/null)"
  if [[ -n "$leftovers" ]]; then
    printf 'unexpected candidate left behind: %s\n' "$leftovers"
    return 1
  fi
}

# ── Argv array shape and argument fidelity ───────────────────────────────────

@test "sandbox command is an argv array that wraps the resolved DAW" {
  load_sandbox
  configure_sandbox

  build_command fake-daw

  [ "${#SANDBOX_COMMAND[@]}" -gt 10 ]
  [ "${SANDBOX_COMMAND[0]}" = "$(command -v bwrap)" ]
  [ "${SANDBOX_COMMAND[-1]}" = "$FIXTURE_BIN/fake-daw" ]
  assert_sequence -- "$FIXTURE_BIN/fake-daw"
}

@test "sandbox command preserves DAW arguments exactly" {
  load_sandbox
  configure_sandbox

  build_command fake-daw "my project.rpp" '*' '--fresh' '$(touch /pwned)' \
    'tab	separated'

  local total="${#SANDBOX_COMMAND[@]}"
  [ "${SANDBOX_COMMAND[total - 5]}" = "my project.rpp" ]
  [ "${SANDBOX_COMMAND[total - 4]}" = '*' ]
  [ "${SANDBOX_COMMAND[total - 3]}" = '--fresh' ]
  [ "${SANDBOX_COMMAND[total - 2]}" = '$(touch /pwned)' ]
  [ "${SANDBOX_COMMAND[total - 1]}" = 'tab	separated' ]
  [ ! -e /pwned ]
}

@test "sandbox command isolates namespaces and dies with its parent" {
  load_sandbox
  configure_sandbox

  build_command fake-daw

  assert_sequence --unshare-user
  assert_sequence --unshare-pid
  assert_sequence --unshare-ipc
  assert_sequence --unshare-uts
  assert_sequence --unshare-cgroup-try
  assert_sequence --die-with-parent
  assert_sequence --new-session
  assert_sequence --proc /proc
  assert_sequence --dev /dev
  assert_sequence --tmpfs /tmp
}

# ── Production state stays read-only ─────────────────────────────────────────

@test "sandbox mounts the production prefix read-only and the clone writable" {
  load_sandbox
  configure_sandbox

  build_command fake-daw

  assert_sequence --ro-bind "$REAL_PREFIX" "$REAL_PREFIX"
  assert_sequence --bind "$COPY" "$COPY"
  assert_read_only "$REAL_PREFIX"
  assert_read_only "$REAL_PREFIX/drive_c/production.txt"
  assert_writable "$COPY"
  assert_writable "$COPY/drive_c"
}

@test "sandbox mounts production plugin roots read-only" {
  load_sandbox
  configure_sandbox

  build_command fake-daw

  local plugin_root
  for plugin_root in .vst .vst3 .clap; do
    assert_sequence --ro-bind "$PRODUCTION_HOME/$plugin_root" \
      "$PRODUCTION_HOME/$plugin_root"
    assert_read_only "$PRODUCTION_HOME/$plugin_root"
    assert_read_only "$PRODUCTION_HOME/$plugin_root/yabridge"
  done
}

@test "sandbox never binds production yabridge directories writable" {
  load_sandbox
  configure_sandbox

  build_command fake-daw

  local plugin_root
  for plugin_root in .vst .vst3 .clap; do
    refute_sequence --bind "$PRODUCTION_HOME/$plugin_root/yabridge" \
      "$PRODUCTION_HOME/$plugin_root/yabridge"
    assert_read_only "$PRODUCTION_HOME/$plugin_root/yabridge/Production.so"
  done
}

# A production plugin root is often a symlink to storage elsewhere. Skipping it
# would leave those bridges outside every boundary the launcher enforces, and
# protecting only the lexical `$HOME/.vst` name would let `--writable-path`
# reach the same directory under its canonical name.
alias_plugin_root() {
  local name="$1"
  local target="$2"
  mkdir -p "$target/yabridge"
  printf '%s\n' 'production bridge' > "$target/yabridge/Production.so"
  rm -rf "$PRODUCTION_HOME/$name"
  ln -s "$target" "$PRODUCTION_HOME/$name"
}

@test "sandbox exposes the canonical target of a symlinked plugin root read-only" {
  load_sandbox
  local target="$BATS_TEST_TMPDIR/external-vst"
  alias_plugin_root .vst "$target"
  configure_sandbox

  build_command fake-daw

  assert_sequence --ro-bind "$target" "$target"
  refute_sequence --bind "$target" "$target"
  assert_read_only "$target"
  assert_read_only "$target/yabridge/Production.so"
}

@test "writable paths reject the canonical target of a symlinked plugin root" {
  load_sandbox
  local target="$BATS_TEST_TMPDIR/external-vst"
  alias_plugin_root .vst "$target"
  configure_sandbox

  run validate_writable_path "$target"
  [ "$status" -ne 0 ]
  [[ "$output" == *"protected"* ]]

  run validate_writable_path "$target/yabridge"
  [ "$status" -ne 0 ]
  [[ "$output" == *"protected"* ]]

  # The alias itself is refused too, by the earlier and more precise canonical
  # path check rather than by the overlap check.
  run validate_writable_path "$PRODUCTION_HOME/.vst"
  [ "$status" -ne 0 ]
  [[ "$output" == *"canonical"* ]]
}

@test "sandbox refuses a plugin root alias that does not resolve" {
  load_sandbox
  rm -rf "$PRODUCTION_HOME/.vst"
  ln -s "$BATS_TEST_TMPDIR/absent-vst" "$PRODUCTION_HOME/.vst"
  configure_sandbox

  run build_command fake-daw

  [ "$status" -ne 0 ]
  [[ "$output" == *"plugin root"* ]]
}

@test "sandbox refuses a plugin root alias that is not a directory" {
  load_sandbox
  printf '%s\n' 'not a plugin root' > "$BATS_TEST_TMPDIR/vst-file"
  rm -rf "$PRODUCTION_HOME/.vst"
  ln -s "$BATS_TEST_TMPDIR/vst-file" "$PRODUCTION_HOME/.vst"
  configure_sandbox

  run build_command fake-daw

  [ "$status" -ne 0 ]
  [[ "$output" == *"plugin root"* ]]
}

@test "sandbox refuses a plugin root alias that widens to the real home" {
  load_sandbox
  rm -rf "$PRODUCTION_HOME/.vst"
  ln -s "$PRODUCTION_HOME" "$PRODUCTION_HOME/.vst"
  configure_sandbox

  run build_command fake-daw

  [ "$status" -ne 0 ]
  [[ "$output" == *"plugin root"* ]]
  [[ "$output" == *"home"* ]]
}

@test "sandbox refuses a plugin root alias that widens above the real home" {
  load_sandbox
  rm -rf "$PRODUCTION_HOME/.vst3"
  ln -s "$BATS_TEST_TMPDIR" "$PRODUCTION_HOME/.vst3"
  configure_sandbox

  run build_command fake-daw

  [ "$status" -ne 0 ]
  [[ "$output" == *"plugin root"* ]]
}

@test "sandbox exposes two plugin roots sharing one target exactly once" {
  load_sandbox
  local target="$BATS_TEST_TMPDIR/shared-plugins"
  alias_plugin_root .vst "$target"
  alias_plugin_root .vst3 "$target"
  configure_sandbox

  build_command fake-daw

  assert_sequence --ro-bind "$target" "$target"
  assert_read_only "$target/yabridge/Production.so"
  [ "$(printf '%s\n' ${SANDBOX_COMMAND[@]+"${SANDBOX_COMMAND[@]}"} |
    grep -cFx "$target")" -eq 2 ]
}

@test "sandbox never binds the production home" {
  load_sandbox
  configure_sandbox

  build_command fake-daw

  refute_sequence --bind "$PRODUCTION_HOME" "$PRODUCTION_HOME"
  refute_sequence --ro-bind "$PRODUCTION_HOME" "$PRODUCTION_HOME"
  refute_exposed_source "$PRODUCTION_HOME/private-notes"
}

@test "sandbox keeps the isolated home and isolation state writable" {
  load_sandbox
  configure_sandbox

  build_command fake-daw

  assert_sequence --bind "$ISOLATION" "$ISOLATION"
  assert_writable "$ISOLATION"
  assert_writable "$ISOLATED_HOME"
  assert_writable "$ISOLATED_HOME/.vst/yabridge"
}

@test "sandbox exports the isolated home instead of the production home" {
  load_sandbox
  configure_sandbox

  build_command fake-daw

  assert_sequence --setenv HOME "$ISOLATED_HOME"
  assert_sequence --setenv XDG_CONFIG_HOME "$ISOLATED_HOME/.config"
  assert_sequence --setenv XDG_DATA_HOME "$ISOLATED_HOME/.local/share"
  assert_sequence --setenv XDG_RUNTIME_DIR "$RUNTIME_DESTINATION"
  refute_sequence --setenv HOME "$PRODUCTION_HOME"
}

@test "sandbox binds the project root read-only for wine and yabridge" {
  load_sandbox
  configure_sandbox

  build_command fake-daw

  assert_sequence --ro-bind "$FIXTURE_ROOT" "$FIXTURE_ROOT"
  assert_read_only "$YABRIDGE_HOME/libyabridge-chainloader-vst2.so"
  assert_writable "$COPY"
  assert_writable "$ISOLATION"
}

@test "sandbox binds the resolved DAW install root read-only" {
  load_sandbox
  configure_sandbox

  build_command fake-daw

  assert_sequence --ro-bind "$FIXTURE_BIN" "$FIXTURE_BIN"
  assert_read_only "$FIXTURE_BIN/fake-daw"
}

@test "sandbox widens a bin directory to its self-contained install root" {
  load_sandbox
  configure_sandbox
  local install="$BATS_TEST_TMPDIR/apps/Studio"
  mkdir -p "$install/bin" "$install/lib"
  printf '%s\n' 'library' > "$install/lib/libstudio.so"
  cp "$FIXTURE_BIN/fake-daw" "$install/bin/studio"
  chmod +x "$install/bin/studio"

  build_command "$install/bin/studio"

  assert_sequence --ro-bind "$install" "$install"
  refute_sequence --ro-bind "$install/bin" "$install/bin"
  assert_read_only "$install/lib/libstudio.so"
}

@test "sandbox never widens a DAW install root into the real home" {
  load_sandbox
  configure_sandbox
  mkdir -p "$PRODUCTION_HOME/bin"
  cp "$FIXTURE_BIN/fake-daw" "$PRODUCTION_HOME/bin/studio"
  chmod +x "$PRODUCTION_HOME/bin/studio"

  build_command "$PRODUCTION_HOME/bin/studio"

  assert_sequence --ro-bind "$PRODUCTION_HOME/bin" "$PRODUCTION_HOME/bin"
  refute_sequence --ro-bind "$PRODUCTION_HOME" "$PRODUCTION_HOME"
  refute_exposed_source "$PRODUCTION_HOME/private-notes"
}

# Widening is what makes a self-contained installation usable, but inside the
# real home the parent of `bin` is a home subtree holding far more than the
# DAW, so no widening happens there at all.
@test "sandbox never widens a home bin directory to a broader home subtree" {
  load_sandbox
  configure_sandbox
  mkdir -p "$PRODUCTION_HOME/.local/bin" "$PRODUCTION_HOME/.local/share/keys"
  printf '%s\n' 'secret' > "$PRODUCTION_HOME/.local/share/keys/token"
  cp "$FIXTURE_BIN/fake-daw" "$PRODUCTION_HOME/.local/bin/studio"
  chmod +x "$PRODUCTION_HOME/.local/bin/studio"

  build_command "$PRODUCTION_HOME/.local/bin/studio"

  assert_sequence --ro-bind "$PRODUCTION_HOME/.local/bin" \
    "$PRODUCTION_HOME/.local/bin"
  refute_sequence --ro-bind "$PRODUCTION_HOME/.local" "$PRODUCTION_HOME/.local"
  refute_exposed_source "$PRODUCTION_HOME/.local/share/keys/token"
  assert_read_only "$PRODUCTION_HOME/.local/bin/studio"
}

@test "sandbox never widens a nested home installation to its parent" {
  load_sandbox
  configure_sandbox
  mkdir -p "$PRODUCTION_HOME/opt/Studio/bin" "$PRODUCTION_HOME/opt/Studio/lib"
  printf '%s\n' 'library' > "$PRODUCTION_HOME/opt/Studio/lib/libstudio.so"
  cp "$FIXTURE_BIN/fake-daw" "$PRODUCTION_HOME/opt/Studio/bin/studio"
  chmod +x "$PRODUCTION_HOME/opt/Studio/bin/studio"

  build_command "$PRODUCTION_HOME/opt/Studio/bin/studio"

  assert_sequence --ro-bind "$PRODUCTION_HOME/opt/Studio/bin" \
    "$PRODUCTION_HOME/opt/Studio/bin"
  refute_sequence --ro-bind "$PRODUCTION_HOME/opt/Studio" \
    "$PRODUCTION_HOME/opt/Studio"
  refute_sequence --ro-bind "$PRODUCTION_HOME/opt" "$PRODUCTION_HOME/opt"
  refute_exposed_source "$PRODUCTION_HOME/opt/Studio/lib/libstudio.so"
}

@test "sandbox still widens a self-contained installation outside the home" {
  load_sandbox
  configure_sandbox
  local install="$BATS_TEST_TMPDIR/apps/Outside"
  mkdir -p "$install/bin" "$install/lib"
  printf '%s\n' 'library' > "$install/lib/libstudio.so"
  cp "$FIXTURE_BIN/fake-daw" "$install/bin/studio"
  chmod +x "$install/bin/studio"

  build_command "$install/bin/studio"

  assert_sequence --ro-bind "$install" "$install"
  assert_read_only "$install/lib/libstudio.so"
}

@test "sandbox refuses a DAW install root at the filesystem root" {
  load_sandbox
  configure_sandbox

  run sandbox_daw_install_root /studio

  [ "$status" -ne 0 ]
  [[ "$output" == *"install root"* ]]
}

@test "sandbox refuses a DAW installed directly in the real home" {
  load_sandbox
  configure_sandbox
  cp "$FIXTURE_BIN/fake-daw" "$PRODUCTION_HOME/studio"
  chmod +x "$PRODUCTION_HOME/studio"

  run build_command "$PRODUCTION_HOME/studio"

  [ "$status" -ne 0 ]
  [[ "$output" == *"install root"* ]]
  [[ "$output" == *"home"* ]]
}

@test "sandbox refuses a DAW install root above the real home" {
  load_sandbox
  configure_sandbox
  cp "$FIXTURE_BIN/fake-daw" "$BATS_TEST_TMPDIR/studio"
  chmod +x "$BATS_TEST_TMPDIR/studio"

  run build_command "$BATS_TEST_TMPDIR/studio"

  [ "$status" -ne 0 ]
  [[ "$output" == *"install root"* ]]
}

# ── One resolved DAW across preflight and construction ───────────────────────

@test "command construction reuses the executable the preflight resolved" {
  load_sandbox
  configure_sandbox
  resolve_daw_executable fake-daw
  [ "$SANDBOX_DAW_PATH" = "$FIXTURE_BIN/fake-daw" ]

  build_command "$SANDBOX_DAW_PATH"

  assert_sequence -- "$FIXTURE_BIN/fake-daw"
  [ "$SANDBOX_DAW_PATH" = "$FIXTURE_BIN/fake-daw" ]
}

@test "command construction requires a DAW the preflight already resolved" {
  load_sandbox
  configure_sandbox
  SANDBOX_DAW_PATH=""

  run build_bwrap_command SANDBOX_COMMAND "$FIXTURE_BIN/fake-daw"

  [ "$status" -ne 0 ]
  [[ "$output" == *"preflight"* ]]
}

@test "command construction refuses a DAW that resolves elsewhere after the preflight" {
  load_sandbox
  configure_sandbox
  resolve_daw_executable fake-daw
  local resolved="$SANDBOX_DAW_PATH"
  mkdir -p "$BATS_TEST_TMPDIR/shadow-bin"
  cp "$FIXTURE_BIN/fake-daw" "$BATS_TEST_TMPDIR/shadow-bin/fake-daw"
  chmod +x "$BATS_TEST_TMPDIR/shadow-bin/fake-daw"

  PATH="$BATS_TEST_TMPDIR/shadow-bin:$PATH" \
    run build_bwrap_command SANDBOX_COMMAND fake-daw

  [ "$status" -ne 0 ]
  [[ "$output" == *"preflight"* ]]
  [ "$SANDBOX_DAW_PATH" = "$resolved" ]
}

@test "command construction refuses a DAW removed after the preflight" {
  load_sandbox
  configure_sandbox
  resolve_daw_executable fake-daw
  rm -f "$FIXTURE_BIN/fake-daw"

  run build_bwrap_command SANDBOX_COMMAND fake-daw

  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
}

# ── Input preflight, before anything is cloned or generated ──────────────────

@test "input preflight accepts a resolved DAW and real plugin roots" {
  load_sandbox
  configure_sandbox
  resolve_daw_executable fake-daw

  run assert_sandbox_inputs

  [ "$status" -eq 0 ]
}

@test "input preflight refuses a DAW installed directly in the real home" {
  load_sandbox
  configure_sandbox
  cp "$FIXTURE_BIN/fake-daw" "$PRODUCTION_HOME/studio"
  chmod +x "$PRODUCTION_HOME/studio"
  resolve_daw_executable "$PRODUCTION_HOME/studio"

  run assert_sandbox_inputs

  [ "$status" -ne 0 ]
  [[ "$output" == *"install root"* ]]
}

@test "input preflight refuses an unusable plugin-root alias" {
  load_sandbox
  configure_sandbox
  resolve_daw_executable fake-daw
  rm -rf "$PRODUCTION_HOME/.vst"
  ln -s "$BATS_TEST_TMPDIR/absent-vst" "$PRODUCTION_HOME/.vst"

  run assert_sandbox_inputs

  [ "$status" -ne 0 ]
  [[ "$output" == *"plugin root"* ]]
}

@test "input preflight requires a resolved DAW" {
  load_sandbox
  configure_sandbox
  SANDBOX_DAW_PATH=""

  run assert_sandbox_inputs

  [ "$status" -ne 0 ]
  [[ "$output" == *"preflight"* ]]
}

# ── Mount plan conflicts ─────────────────────────────────────────────────────

@test "sandbox rejects a duplicate mount destination" {
  load_sandbox
  configure_sandbox
  SANDBOX_MOUNT_DESTINATIONS=()
  sandbox_register_destination "$PROJECTS"

  run sandbox_register_destination "$PROJECTS"

  [ "$status" -ne 0 ]
  [[ "$output" == *"duplicate"* ]]
}

@test "sandbox rejects a writable mount that would shadow a narrower one" {
  load_sandbox
  configure_sandbox
  mkdir -p "$PROJECTS/inner"
  SANDBOX_MOUNT_DESTINATIONS=()
  SANDBOX_MOUNT_ARGUMENTS=()
  SANDBOX_MOUNT_PASSTHROUGH=()
  sandbox_add_mount --ro-bind "$PROJECTS/inner" "$PROJECTS/inner"

  run sandbox_add_writable_mount "$PROJECTS"

  [ "$status" -ne 0 ]
  [[ "$output" == *"shadow"* ]]
}

# Validation rejects an overlapping writable path first, so this proves the
# second, independent layer: even an unvalidated request cannot shadow the
# mounts the sandbox already decided on.
@test "sandbox refuses to build when a writable path shadows the project root" {
  load_sandbox
  configure_sandbox
  SANDBOX_WRITABLE_PATHS=("$FIXTURE_ROOT")

  run build_command fake-daw

  [ "$status" -ne 0 ]
  [[ "$output" == *"shadow"* ]]
}

# ── Network isolation ────────────────────────────────────────────────────────

@test "sandbox unshares the network by default" {
  load_sandbox
  configure_sandbox

  build_command fake-daw

  assert_sequence --unshare-net
}

@test "sandbox shares host networking only when explicitly requested" {
  load_sandbox
  configure_sandbox
  SANDBOX_NETWORK=true

  build_command fake-daw

  refute_sequence --unshare-net
}

# ── Explicit writable project and output paths ───────────────────────────────

@test "sandbox binds only explicitly approved writable paths" {
  load_sandbox
  configure_sandbox
  local other="$BATS_TEST_TMPDIR/not-approved"
  mkdir -p "$other"
  SANDBOX_WRITABLE_PATHS=("$PROJECTS")

  build_command fake-daw

  assert_sequence --bind "$PROJECTS" "$PROJECTS"
  assert_writable "$PROJECTS"
  refute_sequence --bind "$other" "$other"
  refute_sequence --ro-bind "$other" "$other"
}

@test "writable paths reject relative, missing and option-looking values" {
  load_sandbox
  configure_sandbox

  run validate_writable_path "relative/projects"
  [ "$status" -ne 0 ]
  [[ "$output" == *"absolute path"* ]]

  run validate_writable_path "$BATS_TEST_TMPDIR/absent"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not exist"* ]]

  run validate_writable_path "--network"
  [ "$status" -ne 0 ]
  [[ "$output" == *"option"* ]]

  run validate_writable_path "$PROJECTS:$BATS_TEST_TMPDIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"':'"* ]]

  run validate_writable_path "$PROJECTS
$BATS_TEST_TMPDIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"newline"* ]]

  run validate_writable_path "$PROJECTS"
  [ "$status" -eq 0 ]
}

@test "writable paths reject symlink aliases and noncanonical values" {
  load_sandbox
  configure_sandbox
  ln -s "$PROJECTS" "$BATS_TEST_TMPDIR/projects-link"

  run validate_writable_path "$BATS_TEST_TMPDIR/projects-link"
  [ "$status" -ne 0 ]
  [[ "$output" == *"canonical"* ]]

  run validate_writable_path "$BATS_TEST_TMPDIR/./projects"
  [ "$status" -ne 0 ]
  [[ "$output" == *"canonical"* ]]

  run validate_writable_path "$PROJECTS/../projects"
  [ "$status" -ne 0 ]
  [[ "$output" == *"canonical"* ]]
}

@test "writable paths reject a file that is not a directory" {
  load_sandbox
  configure_sandbox
  printf '%s\n' 'not a directory' > "$BATS_TEST_TMPDIR/project-file"

  run validate_writable_path "$BATS_TEST_TMPDIR/project-file"

  [ "$status" -ne 0 ]
  [[ "$output" == *"directory"* ]]
}

@test "writable paths reject overlap with protected production state" {
  load_sandbox
  configure_sandbox

  local protected
  for protected in \
    "$REAL_PREFIX" \
    "$REAL_PREFIX/drive_c" \
    "$PRODUCTION_HOME/.audio-production" \
    "$PRODUCTION_HOME/.vst" \
    "$PRODUCTION_HOME/.vst3/yabridge" \
    "$PRODUCTION_HOME" \
    "$COPY" \
    "$ISOLATION" \
    "$ISOLATED_HOME" \
    "$FIXTURE_ROOT" \
    /usr \
    /etc \
    /; do
    run validate_writable_path "$protected"
    [ "$status" -ne 0 ]
    [[ "$output" == *"protected"* ]]
  done
}

@test "writable paths reject a repeated destination" {
  load_sandbox
  configure_sandbox
  SANDBOX_WRITABLE_PATHS=("$PROJECTS")

  run validate_writable_path "$PROJECTS"

  [ "$status" -ne 0 ]
  [[ "$output" == *"already"* ]]
}

# ── Native plugin directories ────────────────────────────────────────────────
#
# `--native-plugin-path` adds a read-only bind late in the mount plan and puts
# the same directory on VST_PATH. Both halves are dangerous when the value is
# broad: Bubblewrap applies mounts in order, so a late broad bind replaces the
# narrower decisions already made, and a plugin path that reaches production
# bridges reintroduces exactly the production yabridge this launcher exists to
# keep out of an isolated run.

@test "native plugin paths reject roots that would shadow the sandbox" {
  load_sandbox
  configure_sandbox

  local broad
  for broad in / /proc /dev /tmp /run /usr "$PRODUCTION_HOME" \
    "$BATS_TEST_TMPDIR"; do
    [ -d "$broad" ] || continue
    run validate_sandbox_native_plugin_path "$broad"
    [ "$status" -ne 0 ]
    [[ "$output" == *"--native-plugin-path"* ]]
  done
}

@test "native plugin paths reject production plugin roots and their aliases" {
  load_sandbox
  local target="$BATS_TEST_TMPDIR/external-vst"
  alias_plugin_root .vst "$target"
  configure_sandbox

  run validate_sandbox_native_plugin_path "$PRODUCTION_HOME/.vst3/yabridge"
  [ "$status" -ne 0 ]
  [[ "$output" == *"protected"* ]]

  # The canonical name of a symlinked plugin root is the same production
  # bridges under a different spelling.
  run validate_sandbox_native_plugin_path "$target/yabridge"
  [ "$status" -ne 0 ]
  [[ "$output" == *"protected"* ]]

  run validate_sandbox_native_plugin_path "$PRODUCTION_HOME/.vst"
  [ "$status" -ne 0 ]
  [[ "$output" == *"canonical"* ]]
}

@test "native plugin paths reject project, prefix, clone and isolation trees" {
  load_sandbox
  configure_sandbox
  mkdir -p "$COPY/drive_c/plugins"

  local protected
  for protected in "$FIXTURE_ROOT" "$YABRIDGE_HOME" "$REAL_PREFIX" \
    "$REAL_PREFIX/drive_c" "$COPY" "$COPY/drive_c/plugins" "$ISOLATION" \
    "$ISOLATED_HOME/.vst/yabridge"; do
    run validate_sandbox_native_plugin_path "$protected"
    [ "$status" -ne 0 ]
    [[ "$output" == *"protected"* ]]
  done
}

@test "native plugin paths reject a repeated directory" {
  load_sandbox
  configure_sandbox
  mkdir -p "$BATS_TEST_TMPDIR/native"
  resolve_daw_executable fake-daw
  SANDBOX_NATIVE_PLUGIN_PATHS=("$BATS_TEST_TMPDIR/native"
    "$BATS_TEST_TMPDIR/native")

  run assert_sandbox_inputs

  [ "$status" -ne 0 ]
  [[ "$output" == *"already"* ]]
}

# A directory inside a system root the sandbox already binds read-only in full
# is what this option is for: it adds no mount, shadows nothing, and the DAW
# sees the same read-only content it would have seen anyway.
@test "native plugin paths accept a narrow system plugin directory" {
  load_sandbox
  configure_sandbox
  [ -d /usr/lib/vst3 ] || skip "no system VST3 directory at /usr/lib/vst3"

  run validate_sandbox_native_plugin_path /usr/lib/vst3
  [ "$status" -eq 0 ]

  SANDBOX_NATIVE_PLUGIN_PATHS=(/usr/lib/vst3)
  build_command fake-daw

  assert_sequence --ro-bind /usr /usr
  refute_sequence --bind /usr/lib/vst3 /usr/lib/vst3
  assert_read_only /usr/lib/vst3
}

@test "command construction refuses a native plugin path it was handed late" {
  load_sandbox
  configure_sandbox
  SANDBOX_NATIVE_PLUGIN_PATHS=("$PRODUCTION_HOME/.vst/yabridge")

  run build_command fake-daw

  [ "$status" -ne 0 ]
  [[ "$output" == *"--native-plugin-path"* ]]
}

@test "input preflight refuses a native plugin path at the filesystem root" {
  load_sandbox
  configure_sandbox
  resolve_daw_executable fake-daw
  SANDBOX_NATIVE_PLUGIN_PATHS=(/)

  run assert_sandbox_inputs

  [ "$status" -ne 0 ]
  [[ "$output" == *"--native-plugin-path"* ]]
}

# ── The source prefix may not live in project state ──────────────────────────

@test "input preflight refuses a source prefix inside the project tree" {
  load_sandbox
  configure_sandbox
  resolve_daw_executable fake-daw

  local nested
  for nested in "$FIXTURE_ROOT/nested-prefix" "$COPY" "$ISOLATION/prefix"; do
    SANDBOX_REAL_PREFIX="$nested"
    run assert_sandbox_inputs
    [ "$status" -ne 0 ]
    [[ "$output" == *"source prefix"* ]]
  done
}

@test "launcher refuses a source prefix inside the project tree before cloning" {
  make_prefix "$FIXTURE_ROOT/nested-prefix"

  run_daw_fixture --prefix "$FIXTURE_ROOT/nested-prefix" fake-daw

  [ "$status" -ne 0 ]
  [[ "$output" == *"source prefix"* ]]
  refute_launcher_mutation
}

# ── Narrow runtime, display and audio exposure ───────────────────────────────

@test "sandbox provides an isolated runtime directory without the host one" {
  load_sandbox
  configure_sandbox

  build_command fake-daw

  assert_sequence --tmpfs "$RUNTIME_DESTINATION"
  refute_sequence --bind "$RUNTIME" "$RUNTIME_DESTINATION"
  refute_sequence --ro-bind "$RUNTIME" "$RUNTIME_DESTINATION"
  assert_writable "$RUNTIME_DESTINATION"
}

@test "sandbox binds only the display and audio sockets that exist" {
  load_sandbox
  configure_sandbox
  mkdir -p "$RUNTIME/pulse"
  : > "$RUNTIME/pulse/native"
  : > "$RUNTIME/wayland-1"
  : > "$X11_DIR/X7"
  export DISPLAY=":7.0"
  export WAYLAND_DISPLAY="wayland-1"

  build_command fake-daw

  assert_sequence --ro-bind "$RUNTIME/pulse/native" \
    "$RUNTIME_DESTINATION/pulse/native"
  assert_sequence --ro-bind "$RUNTIME/wayland-1" \
    "$RUNTIME_DESTINATION/wayland-1"
  assert_sequence --ro-bind "$X11_DIR/X7" /tmp/.X11-unix/X7
  refute_sequence --ro-bind "$X11_DIR" /tmp/.X11-unix
  refute_sequence --ro-bind "$RUNTIME" "$RUNTIME_DESTINATION"
  assert_read_only "$RUNTIME_DESTINATION/pulse/native"
}

@test "sandbox omits missing optional sockets and devices safely" {
  load_sandbox
  configure_sandbox
  SANDBOX_DEVICE_PATHS=("$BATS_TEST_TMPDIR/absent-device")
  export DISPLAY=":9"
  export WAYLAND_DISPLAY="wayland-9"

  build_command fake-daw

  refute_sequence --ro-bind "$X11_DIR/X9" /tmp/.X11-unix/X9
  refute_sequence --ro-bind "$RUNTIME/wayland-9" \
    "$RUNTIME_DESTINATION/wayland-9"
  refute_sequence --dev-bind "$BATS_TEST_TMPDIR/absent-device" \
    "$BATS_TEST_TMPDIR/absent-device"
  assert_sequence --tmpfs "$RUNTIME_DESTINATION"
}

@test "sandbox binds an existing audio device with device access" {
  load_sandbox
  configure_sandbox
  mkdir -p "$BATS_TEST_TMPDIR/dev-snd"
  SANDBOX_DEVICE_PATHS=("$BATS_TEST_TMPDIR/dev-snd")

  build_command fake-daw

  assert_sequence --dev-bind "$BATS_TEST_TMPDIR/dev-snd" \
    "$BATS_TEST_TMPDIR/dev-snd"
}

@test "sandbox exposes an explicit read-only X authority file only" {
  load_sandbox
  configure_sandbox
  printf '%s\n' 'cookie' > "$PRODUCTION_HOME/.Xauthority"
  export XAUTHORITY="$PRODUCTION_HOME/.Xauthority"

  build_command fake-daw

  assert_sequence --ro-bind "$PRODUCTION_HOME/.Xauthority" \
    "$PRODUCTION_HOME/.Xauthority"
  assert_read_only "$PRODUCTION_HOME/.Xauthority"
  refute_exposed_source "$PRODUCTION_HOME/private-notes"
}

# ── Fail-closed preflight ────────────────────────────────────────────────────

@test "missing bubblewrap fails closed with an actionable diagnostic" {
  load_sandbox
  mkdir -p "$BATS_TEST_TMPDIR/empty-bin"

  PATH="$BATS_TEST_TMPDIR/empty-bin" run require_bwrap

  [ "$status" -ne 0 ]
  [[ "$output" == *"bwrap"* ]]
  [[ "$output" == *"bubblewrap"* ]]
}

@test "an unusable namespace preflight fails closed with the exact probe" {
  load_sandbox
  configure_sandbox
  export SANDBOX_TEST_BWRAP_FAIL=true

  run assert_sandbox_namespaces

  [ "$status" -ne 0 ]
  [[ "$output" == *"namespace"* ]]
  [[ "$output" == *"--unshare-user"* ]]
  [[ "$output" == *"No permissions to creating new namespace"* ]]
}

@test "the preflight falls back to a setuid sandbox without user namespaces" {
  load_sandbox
  export SANDBOX_TEST_BWRAP_FAIL_USERNS=true
  configure_sandbox

  [ "$SANDBOX_UNSHARE_USER" = false ]
  build_command fake-daw

  refute_sequence --unshare-user
  assert_sequence --unshare-pid
}

@test "command construction refuses to run before the preflight" {
  load_sandbox
  require_bwrap
  SANDBOX_PROJECT_ROOT="$FIXTURE_ROOT"
  SANDBOX_REAL_PREFIX="$REAL_PREFIX"
  SANDBOX_CLONE="$COPY"
  SANDBOX_ISOLATION="$ISOLATION"
  SANDBOX_ISOLATED_HOME="$ISOLATED_HOME"

  run build_bwrap_command SANDBOX_COMMAND fake-daw

  [ "$status" -ne 0 ]
  [[ "$output" == *"namespace"* ]]
}

@test "command construction refuses an unresolvable DAW" {
  load_sandbox
  configure_sandbox

  run build_command definitely-not-a-daw
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]

  printf '%s\n' 'data' > "$BATS_TEST_TMPDIR/not-executable"
  run build_command "$BATS_TEST_TMPDIR/not-executable"
  [ "$status" -ne 0 ]
  [[ "$output" == *"executable"* ]]
}

# ── Launcher integration with the sandbox ────────────────────────────────────

@test "launcher executes the DAW through bubblewrap" {
  run_daw_fixture --prefix "$REAL_PREFIX" fake-daw

  [ "$status" -eq 0 ]
  [ -f "$DAW_ENV_FILE" ]
  # Only bwrap itself can record a launch line, so this is proof the DAW was
  # executed through the sandbox rather than directly.
  [ "$(launched_argv | wc -l)" -eq 1 ]
  [[ "$(launched_argv)" == *" -- $FIXTURE_BIN/fake-daw"* ]]
  [[ "$(launched_argv)" == *" --ro-bind $REAL_PREFIX $REAL_PREFIX "* ]]
  [[ "$(launched_argv)" == *" --bind $COPY $COPY "* ]]
  [ "$(daw_env_value HOME)" = "$ISOLATED_HOME" ]
  [ "$(daw_env_value VST_PATH)" = "$ISOLATED_HOME/.vst/yabridge" ]
  refute grep -Fq "$PRODUCTION_HOME/.vst/yabridge" "$DAW_ENV_FILE"
}

@test "launcher unshares the network unless the option is explicit" {
  run_daw_fixture --prefix "$REAL_PREFIX" fake-daw
  [ "$status" -eq 0 ]
  [[ "$(launched_argv)" == *" --unshare-net "* ]]

  : > "$BWRAP_CALLS"
  run_daw_fixture --network --prefix "$REAL_PREFIX" fake-daw

  [ "$status" -eq 0 ]
  [[ "$(launched_argv)" != *" --unshare-net "* ]]
}

# Host networking is a decision, not an inherited default. A stale export in
# the launching shell must not be able to make it for the user.
@test "launcher ignores an inherited SANDBOX_NETWORK request" {
  export SANDBOX_NETWORK=true

  run_daw_fixture --prefix "$REAL_PREFIX" fake-daw

  [ "$status" -eq 0 ]
  [[ "$(launched_argv)" == *" --unshare-net "* ]]
  [[ "$output" == *"network:     isolated"* ]]
}

@test "launcher still shares the network when SANDBOX_NETWORK is inherited false" {
  export SANDBOX_NETWORK=false

  run_daw_fixture --network --prefix "$REAL_PREFIX" fake-daw

  [ "$status" -eq 0 ]
  [[ "$(launched_argv)" != *" --unshare-net "* ]]
}

@test "launcher binds explicit writable paths and nothing else" {
  run_daw_fixture --prefix "$REAL_PREFIX" --writable-path "$PROJECTS" fake-daw

  [ "$status" -eq 0 ]
  [[ "$(launched_argv)" == *" --bind $PROJECTS $PROJECTS "* ]]
}

@test "launcher rejects a writable path that overlaps production state" {
  run_daw_fixture --prefix "$REAL_PREFIX" \
    --writable-path "$PRODUCTION_HOME/.vst" fake-daw

  [ "$status" -eq 2 ]
  [[ "$output" == *"protected"* ]]
  [ ! -e "$DAW_ENV_FILE" ]
  [ ! -e "$COPY/.yabridge-staging-source" ]
  [ "$(sync_call_count)" -eq 0 ]
}

@test "launcher rejects a writable path aliased by a symlinked plugin root" {
  local target="$BATS_TEST_TMPDIR/external-vst"
  alias_plugin_root .vst "$target"

  run_daw_fixture --prefix "$REAL_PREFIX" --writable-path "$target" fake-daw

  [ "$status" -eq 2 ]
  [[ "$output" == *"protected"* ]]
  [ ! -e "$DAW_ENV_FILE" ]
  [ ! -e "$COPY/.yabridge-staging-source" ]
  [ "$(sync_call_count)" -eq 0 ]
}

# The install root and the production plugin roots decide what the sandbox will
# expose, so they are inputs to validate, not results to discover after the
# prefix has already been cloned and bridges generated.
@test "launcher refuses a DAW installed directly in the real home before cloning" {
  cp "$FIXTURE_BIN/fake-daw" "$PRODUCTION_HOME/studio"
  chmod +x "$PRODUCTION_HOME/studio"

  run_daw_fixture --prefix "$REAL_PREFIX" "$PRODUCTION_HOME/studio"

  [ "$status" -ne 0 ]
  [[ "$output" == *"install root"* ]]
  [[ "$output" == *"home"* ]]
  refute_launcher_mutation
}

@test "launcher refuses a broken plugin-root alias before cloning" {
  rm -rf "$PRODUCTION_HOME/.vst"
  ln -s "$BATS_TEST_TMPDIR/absent-vst" "$PRODUCTION_HOME/.vst"

  run_daw_fixture --prefix "$REAL_PREFIX" fake-daw

  [ "$status" -ne 0 ]
  [[ "$output" == *"plugin root"* ]]
  refute_launcher_mutation
}

@test "launcher refuses a plugin-root alias widening to the real home before cloning" {
  rm -rf "$PRODUCTION_HOME/.clap"
  ln -s "$PRODUCTION_HOME" "$PRODUCTION_HOME/.clap"

  run_daw_fixture --prefix "$REAL_PREFIX" fake-daw

  [ "$status" -ne 0 ]
  [[ "$output" == *"plugin root"* ]]
  refute_launcher_mutation
}

@test "launcher refuses a shadowing native plugin path before cloning" {
  run_daw_fixture --prefix "$REAL_PREFIX" --native-plugin-path / fake-daw

  [ "$status" -ne 0 ]
  [[ "$output" == *"--native-plugin-path"* ]]
  refute_launcher_mutation
}

@test "launcher refuses a native plugin path at the real home before cloning" {
  run_daw_fixture --prefix "$REAL_PREFIX" \
    --native-plugin-path "$PRODUCTION_HOME" fake-daw

  [ "$status" -ne 0 ]
  [[ "$output" == *"real home"* ]]
  refute_launcher_mutation
}

@test "launcher refuses a production yabridge native plugin path before cloning" {
  run_daw_fixture --prefix "$REAL_PREFIX" \
    --native-plugin-path "$PRODUCTION_HOME/.vst/yabridge" fake-daw

  [ "$status" -ne 0 ]
  [[ "$output" == *"protected"* ]]
  refute_launcher_mutation
}

@test "launcher refuses a symlinked production plugin alias before cloning" {
  local target="$BATS_TEST_TMPDIR/external-vst"
  alias_plugin_root .vst "$target"

  run_daw_fixture --prefix "$REAL_PREFIX" \
    --native-plugin-path "$PRODUCTION_HOME/.vst/yabridge" fake-daw
  [ "$status" -ne 0 ]
  [[ "$output" == *"canonical"* ]]
  refute_launcher_mutation

  run_daw_fixture --prefix "$REAL_PREFIX" \
    --native-plugin-path "$target/yabridge" fake-daw
  [ "$status" -ne 0 ]
  [[ "$output" == *"protected"* ]]
  refute_launcher_mutation
}

@test "launcher accepts a narrow system native plugin path" {
  [ -d /usr/lib/vst3 ] || skip "no system VST3 directory at /usr/lib/vst3"

  run_daw_fixture --prefix "$REAL_PREFIX" \
    --native-plugin-path /usr/lib/vst3 fake-daw

  [ "$status" -eq 0 ]
  [ "$(daw_env_value VST3_PATH)" = \
    "$ISOLATED_HOME/.vst3/yabridge:/usr/lib/vst3" ]
}

@test "launcher rejects a missing writable path value" {
  run_daw_fixture --prefix "$REAL_PREFIX" --writable-path

  [ "$status" -eq 2 ]
  [[ "$output" == *"--writable-path requires a value"* ]]
  [ ! -e "$DAW_ENV_FILE" ]
}

@test "launcher fails closed before the DAW when the sandbox is unusable" {
  export SANDBOX_TEST_BWRAP_FAIL=true

  run_daw_fixture --prefix "$REAL_PREFIX" fake-daw

  [ "$status" -ne 0 ]
  [[ "$output" == *"namespace"* ]]
  [ ! -e "$DAW_ENV_FILE" ]
  [ ! -e "$COPY/.yabridge-staging-source" ]
  [ ! -e "$ISOLATION" ]
  [ "$(sync_call_count)" -eq 0 ]
}

@test "launcher propagates the DAW exit status" {
  export FAKE_DAW_EXIT_STATUS=42

  run_daw_fixture --prefix "$REAL_PREFIX" fake-daw

  [ "$status" -eq 42 ]
  [ -f "$DAW_ENV_FILE" ]
}

@test "launcher propagates a DAW termination signal" {
  run_daw_fixture --prefix "$REAL_PREFIX" suicidal-daw

  [ "$status" -eq 143 ]
}

# ── Live boundary enforcement ────────────────────────────────────────────────

# Command construction is verified above without any kernel support. These are
# the only tests that need real namespaces, so they skip — loudly, naming the
# probe that failed — when host policy forbids them. The launcher itself never
# degrades: it fails closed.
require_live_sandbox() {
  local real_bwrap="/usr/bin/bwrap"
  [ -x "$real_bwrap" ] || skip "bubblewrap is not installed at $real_bwrap"
  if ! "$real_bwrap" --unshare-user --unshare-pid --unshare-ipc --unshare-uts \
    --unshare-cgroup-try --unshare-net --die-with-parent --new-session \
    --ro-bind /usr /usr --proc /proc --dev /dev --tmpfs /tmp \
    --symlink usr/lib /lib64 --symlink usr/bin /bin -- /usr/bin/true \
    >/dev/null 2>"$BATS_TEST_TMPDIR/probe.err"; then
    skip "host policy forbids bubblewrap namespaces: $(cat "$BATS_TEST_TMPDIR/probe.err")"
  fi
  rm -f "$FIXTURE_BIN/bwrap"
}

@test "a sandboxed DAW cannot write production state but can write the clone" {
  require_live_sandbox

  local report="$PROJECTS/report"
  cat > "$FIXTURE_BIN/mutating-daw" <<EOF
#!/bin/bash
{
  if printf 'changed' > "$REAL_PREFIX/drive_c/production.txt" 2>/dev/null; then
    printf 'production-write=succeeded\n'
  else
    printf 'production-write=failed\n'
  fi
  if printf 'injected' \
    > "$PRODUCTION_HOME/.vst/yabridge/Injected.so" 2>/dev/null; then
    printf 'production-bridge-write=succeeded\n'
  else
    printf 'production-bridge-write=failed\n'
  fi
  if printf 'changed' > "$COPY/drive_c/clone.txt" 2>/dev/null; then
    printf 'clone-write=succeeded\n'
  else
    printf 'clone-write=failed\n'
  fi
  if printf 'rendered' > "$PROJECTS/output.wav" 2>/dev/null; then
    printf 'approved-write=succeeded\n'
  else
    printf 'approved-write=failed\n'
  fi
  printf 'production-visible=%s\n' "\$(cat "$REAL_PREFIX/drive_c/production.txt")"
} > "$report"
EOF
  chmod +x "$FIXTURE_BIN/mutating-daw"
  local before
  before="$(sha256sum < "$REAL_PREFIX/drive_c/production.txt")"

  run "$FIXTURE_ROOT/daw-env.sh" --prefix "$REAL_PREFIX" \
    --writable-path "$PROJECTS" mutating-daw

  [ "$status" -eq 0 ]
  [ -f "$report" ]
  grep -Fxq 'production-write=failed' "$report"
  grep -Fxq 'production-bridge-write=failed' "$report"
  grep -Fxq 'clone-write=succeeded' "$report"
  grep -Fxq 'approved-write=succeeded' "$report"
  grep -Fxq 'production-visible=production state' "$report"
  [ "$(sha256sum < "$REAL_PREFIX/drive_c/production.txt")" = "$before" ]
  [ ! -e "$PRODUCTION_HOME/.vst/yabridge/Injected.so" ]
  [ "$(cat "$COPY/drive_c/clone.txt")" = "changed" ]
  [ "$(cat "$PROJECTS/output.wav")" = "rendered" ]
}

@test "a sandboxed DAW cannot write a symlinked production plugin root" {
  require_live_sandbox
  local target="$BATS_TEST_TMPDIR/external-vst"
  alias_plugin_root .vst "$target"

  local report="$PROJECTS/report"
  cat > "$FIXTURE_BIN/aliasing-daw" <<EOF
#!/bin/bash
{
  if printf 'injected' > "$target/yabridge/Injected.so" 2>/dev/null; then
    printf 'alias-create=succeeded\n'
  else
    printf 'alias-create=failed\n'
  fi
  if printf 'changed' > "$target/yabridge/Production.so" 2>/dev/null; then
    printf 'alias-overwrite=succeeded\n'
  else
    printf 'alias-overwrite=failed\n'
  fi
  printf 'alias-visible=%s\n' "\$(cat "$target/yabridge/Production.so")"
} > "$report"
EOF
  chmod +x "$FIXTURE_BIN/aliasing-daw"

  run "$FIXTURE_ROOT/daw-env.sh" --prefix "$REAL_PREFIX" \
    --writable-path "$PROJECTS" aliasing-daw

  [ "$status" -eq 0 ]
  [ -f "$report" ]
  grep -Fxq 'alias-create=failed' "$report"
  grep -Fxq 'alias-overwrite=failed' "$report"
  grep -Fxq 'alias-visible=production bridge' "$report"
  [ ! -e "$target/yabridge/Injected.so" ]
  [ "$(cat "$target/yabridge/Production.so")" = "production bridge" ]
}

# Interfaces are read from /proc/net/dev, which procfs reports per network
# namespace. Nothing here contacts a host or a remote, so the test cannot hang
# on an unreachable network.
@test "a sandboxed DAW sees no real-home sibling and no host network interface" {
  require_live_sandbox
  printf '%s\n' 'private' > "$PRODUCTION_HOME/private-notes"
  mkdir -p "$PRODUCTION_HOME/Documents"

  local report="$PROJECTS/report"
  cat > "$FIXTURE_BIN/probing-daw" <<EOF
#!/bin/bash
{
  if [[ -e "$PRODUCTION_HOME/private-notes" ]]; then
    printf 'home-sibling=visible\n'
  else
    printf 'home-sibling=hidden\n'
  fi
  if [[ -e "$PRODUCTION_HOME/Documents" ]]; then
    printf 'home-documents=visible\n'
  else
    printf 'home-documents=hidden\n'
  fi
  if [[ -e "$REAL_PREFIX/system.reg" ]]; then
    printf 'prefix=visible\n'
  else
    printf 'prefix=hidden\n'
  fi
  printf 'interfaces=%s\n' \
    "\$(cut -d: -f1 /proc/net/dev | tail -n +3 | tr -d ' ' | tr '\n' ' ')"
} > "$report"
EOF
  chmod +x "$FIXTURE_BIN/probing-daw"

  run "$FIXTURE_ROOT/daw-env.sh" --prefix "$REAL_PREFIX" \
    --writable-path "$PROJECTS" probing-daw

  [ "$status" -eq 0 ]
  [ -f "$report" ]
  grep -Fxq 'home-sibling=hidden' "$report"
  grep -Fxq 'home-documents=hidden' "$report"
  # The prefix is deliberately visible read-only; hiding the rest of the home
  # is what this asserts, not hiding the boundary itself.
  grep -Fxq 'prefix=visible' "$report"
  local interfaces
  interfaces="$(sed -n 's/^interfaces=//p' "$report" | tr -s ' ' | sed 's/ *$//')"
  [ "$interfaces" = "lo" ]
}

@test "a sandboxed DAW propagates its exit status and gets a private /tmp" {
  require_live_sandbox
  export FAKE_DAW_EXIT_STATUS=42

  run "$FIXTURE_ROOT/daw-env.sh" --prefix "$REAL_PREFIX" fake-daw

  [ "$status" -eq 42 ]
  # fake-daw writes its report under the host /tmp, which the sandbox replaces
  # with a private tmpfs, so nothing of that write survives outside.
  [ ! -e "$DAW_ENV_FILE" ]
}

@test "a sandboxed DAW termination signal survives the real sandbox" {
  require_live_sandbox

  run "$FIXTURE_ROOT/daw-env.sh" --prefix "$REAL_PREFIX" suicidal-daw

  [ "$status" -eq 143 ]
}

# The record of what a run was is worth only as much as the DAW's inability to
# edit it. It lives under the read-only project root rather than in the
# writable isolation tree, so this proves the kernel refuses every way in:
# rewriting it, truncating it, unlinking it, and replacing its directory entry.
@test "a sandboxed DAW cannot rewrite or delete the run manifest" {
  require_live_sandbox

  local manifest="$FIXTURE_ROOT/run-state/run-manifest.json"
  local report="$PROJECTS/report"
  cat > "$FIXTURE_BIN/tampering-daw" <<EOF
#!/bin/bash
{
  printf 'checksum=%s\n' "\$(sha256sum < "$manifest")"
  if printf 'forged' > "$manifest" 2>/dev/null; then
    printf 'overwrite=succeeded\n'
  else
    printf 'overwrite=failed\n'
  fi
  if printf 'appended' >> "$manifest" 2>/dev/null; then
    printf 'append=succeeded\n'
  else
    printf 'append=failed\n'
  fi
  if rm -f -- "$manifest" 2>/dev/null && [[ ! -e "$manifest" ]]; then
    printf 'delete=succeeded\n'
  else
    printf 'delete=failed\n'
  fi
  if printf 'forged' > "$FIXTURE_ROOT/run-state/other.json" 2>/dev/null; then
    printf 'create=succeeded\n'
  else
    printf 'create=failed\n'
  fi
  printf 'readable=%s\n' "\$(head -c 1 -- "$manifest")"
} > "$report"
EOF
  chmod +x "$FIXTURE_BIN/tampering-daw"

  run "$FIXTURE_ROOT/daw-env.sh" --prefix "$REAL_PREFIX" \
    --writable-path "$PROJECTS" tampering-daw

  [ "$status" -eq 0 ]
  [ -f "$report" ]
  grep -Fxq 'overwrite=failed' "$report"
  grep -Fxq 'append=failed' "$report"
  grep -Fxq 'delete=failed' "$report"
  grep -Fxq 'create=failed' "$report"
  grep -Fxq 'readable={' "$report"
  [ -f "$manifest" ]
  [ ! -e "$FIXTURE_ROOT/run-state/other.json" ]
  # The checksum the DAW saw before it started trying is still the checksum on
  # disk now that it has stopped.
  local observed
  observed="$(sed -n 's/^checksum=//p' "$report")"
  [ -n "$observed" ]
  [ "$(sha256sum < "$manifest")" = "$observed" ]
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$manifest"
}
