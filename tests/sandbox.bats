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
  cp "$PROJECT_ROOT/lib/wine-wait.sh" "$FIXTURE_ROOT/lib/wine-wait.sh"
  chmod +x "$FIXTURE_ROOT/lib/wine-wait.sh"
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

teardown() {
  # Pasta/slirp fakes sleep in the background. Tests that start one must
  # not leak it into later cases or the host.
  if [[ -n "${SANDBOX_MAC_HOLDER_PID:-}" ]]; then
    kill "$SANDBOX_MAC_HOLDER_PID" 2>/dev/null || true
    wait "$SANDBOX_MAC_HOLDER_PID" 2>/dev/null || true
  fi
  if [[ -n "${SANDBOX_TEST_PASTA_PIDS:-}" && -f "$SANDBOX_TEST_PASTA_PIDS" ]]; then
    local leftover
    while IFS= read -r leftover; do
      [[ "$leftover" =~ ^[0-9]+$ ]] || continue
      kill "$leftover" 2>/dev/null || true
      wait "$leftover" 2>/dev/null || true
    done < "$SANDBOX_TEST_PASTA_PIDS"
  fi
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
  SANDBOX_HOST_HOME="$PRODUCTION_HOME"
  SANDBOX_HOST_UID="$(id -u)"
  SANDBOX_HOST_GID="$(id -g)"
  SANDBOX_HOST_USER="$(id -un)"
  SANDBOX_WINESERVER="$FIXTURE_BIN/wineserver"
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

# bwrap cannot mount onto a symlink. Every bind/tmpfs dest must be a real
# directory (or a path that does not exist yet). --symlink recreating a
# merged-/usr link is not a mount and is ignored here.
refute_symlink_mount_destinations() {
  local total="${#SANDBOX_COMMAND[@]}"
  local index flag dest

  for ((index = 0; index < total; index++)); do
    flag="${SANDBOX_COMMAND[index]}"
    case "$flag" in
      --) break ;;
      --ro-bind | --ro-bind-try | --bind | --bind-try | --dev-bind | \
        --dev-bind-try)
        dest="${SANDBOX_COMMAND[index + 2]}"
        ;;
      --tmpfs | --proc | --dev)
        dest="${SANDBOX_COMMAND[index + 1]}"
        ;;
      *) continue ;;
    esac
    if [[ -L "$dest" ]]; then
      printf 'mount destination is a symlink: %s -> %s\n' "$dest" \
        "$(readlink -- "$dest")"
      show_command
      return 1
    fi
  done
}

wrapped_has_sequence() {
  local -a want=("$@")
  local total="${#WRAPPED_COMMAND[@]}"
  local wanted="${#want[@]}"
  local index offset

  for ((index = 0; index + wanted <= total; index++)); do
    for ((offset = 0; offset < wanted; offset++)); do
      [[ "${WRAPPED_COMMAND[index + offset]}" == "${want[offset]}" ]] || break
    done
    if [[ "$offset" -eq "$wanted" ]]; then
      return 0
    fi
  done
  return 1
}

assert_wrapped_sequence() {
  wrapped_has_sequence "$@" && return 0
  printf 'missing wrapped argv sequence:'
  printf ' %q' "$@"
  printf '\n'
  printf 'argv:'
  printf ' %q' ${WRAPPED_COMMAND[@]+"${WRAPPED_COMMAND[@]}"}
  printf '\n'
  return 1
}

refute_wrapped_token() {
  local needle="$1"
  local token
  for token in ${WRAPPED_COMMAND[@]+"${WRAPPED_COMMAND[@]}"}; do
    if [[ "$token" == *"$needle"* ]]; then
      printf 'unexpected wrapped token containing %q: %q\n' "$needle" "$token"
      return 1
    fi
  done
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
  assert_sequence --unshare-uts
  assert_sequence --unshare-cgroup-try
  assert_sequence --die-with-parent
  assert_sequence --new-session
  assert_sequence --proc /proc
  assert_sequence --dev /dev
  # Host X11 MIT-SHM (X_ShmPutImage) needs the host IPC namespace and
  # host /dev/shm. --unshare-ipc makes Wine/DXVK abort after a flash.
  local token
  for token in "${SANDBOX_COMMAND[@]}"; do
    [ "$token" != --unshare-ipc ]
  done
  assert_sequence --bind /dev/shm /dev/shm
  assert_sequence --tmpfs /tmp
}

# Cotton updateBinary tree: exe plus the versioned resources Lua loads
# from GetModuleFileName (installData_app), not only cwd-relative Certs.
seed_xln_updatebinary_tree() {
  local cotton="$1"
  mkdir -p "$cotton/updateBinary/XLN Online Installer/Certs"
  mkdir -p "$cotton/updateBinary/installData/installData_app/XLN Online Installer"
  printf '%s\n' 'installer-image' > "$cotton/updateBinary/XLN Online Installer.exe"
  printf '%s\n' '-----BEGIN CERTIFICATE-----' > \
    "$cotton/updateBinary/XLN Online Installer/Certs/cacert.pem"
  printf '%s\n' '4_7_3 Release1' > \
    "$cotton/updateBinary/installData/installData_app/XLN Online Installer/XLN Online Installer.version"
  printf '%s\n' 'lua-system' > \
    "$cotton/updateBinary/installData/installData_app/XLN Online Installer/LuaSystem.xpak"
}

@test "sandbox pins XLN installer cacert.pem on the clone CAfile path" {
  load_sandbox
  configure_sandbox
  local certs="$COPY/drive_c/ProgramData/XLN Audio/XLN Online Installer/App/XLN Online Installer/Certs"
  local cafile="$COPY/drive_c/ProgramData/XLN Audio/Temp/App/Cotton XLN Online Installer/updateBinary/installData/installData_app/cacert.pem"
  local cache="$FIXTURE_ROOT/run-state/xln-cacert.pem"
  mkdir -p "$certs"
  printf '%s\n' '-----BEGIN CERTIFICATE-----' 'MIIB' '-----END CERTIFICATE-----' > "$certs/cacert.pem"
  sandbox_pin_xln_installer_cacert "$COPY"
  [ -s "$cafile" ]
  [ -s "$cache" ]
  grep -q 'BEGIN CERTIFICATE' "$cafile"
}

@test "sandbox ro-binds the XLN installer CAfile so ReplaceFileW cannot delete it" {
  load_sandbox
  configure_sandbox
  local certs="$COPY/drive_c/ProgramData/XLN Audio/XLN Online Installer/App/XLN Online Installer/Certs"
  local cotton="$COPY/drive_c/ProgramData/XLN Audio/Temp/App/Cotton XLN Online Installer"
  local rel="drive_c/ProgramData/XLN Audio/Temp/App/Cotton XLN Online Installer/updateBinary/installData/installData_app/cacert.pem"
  local cache="$FIXTURE_ROOT/run-state/xln-cacert.pem"
  mkdir -p "$certs"
  printf '%s\n' '-----BEGIN CERTIFICATE-----' 'MIIB' '-----END CERTIFICATE-----' > "$certs/cacert.pem"
  sandbox_pin_xln_installer_cacert "$COPY"
  build_command fake-daw
  assert_sequence --ro-bind "$cache" "$COPY/$rel"
  assert_sequence --ro-bind "$cache" "$REAL_PREFIX/$rel"
  # File bind of cacert.pem only — not the installer exe, not launchCopy/.
  refute_sequence --ro-bind "$cotton/updateBinary/XLN Online Installer.exe"
  refute_sequence --ro-bind "$cotton/launchCopy"
  refute_sequence --ro-bind "$cotton/launchCopy/XLN Online Installer.exe"
}

@test "sandbox chdirs to a Windows exe directory so relative Certs resolve" {
  load_sandbox
  configure_sandbox
  local win_dir="$COPY/drive_c/ProgramData/XLN Audio/Temp/App/Cotton XLN Online Installer/updateBinary"
  mkdir -p "$win_dir"
  build_command fake-daw \
    'C:\ProgramData\XLN Audio\Temp\App\Cotton XLN Online Installer\updateBinary\XLN Online Installer.exe'
  assert_sequence --chdir "$win_dir"
}

@test "sandbox stages the XLN updateBinary installer to launchCopy and leaves the original" {
  load_sandbox
  configure_sandbox
  local cotton="$COPY/drive_c/ProgramData/XLN Audio/Temp/App/Cotton XLN Online Installer"
  local src="$cotton/updateBinary/XLN Online Installer.exe"
  local dest="$cotton/launchCopy/XLN Online Installer.exe"
  seed_xln_updatebinary_tree "$cotton"
  local staged
  staged="$(sandbox_stage_xln_updatebinary_launch_copy "$COPY" \
    'C:\ProgramData\XLN Audio\Temp\App\Cotton XLN Online Installer\updateBinary\XLN Online Installer.exe')"
  [ "$staged" = 'C:\ProgramData\XLN Audio\Temp\App\Cotton XLN Online Installer\launchCopy\XLN Online Installer.exe' ]
  [ -f "$src" ]
  [ -f "$dest" ]
  [ "$(cat "$src")" = installer-image ]
  [ "$(cat "$dest")" = installer-image ]
  [ -f "$cotton/launchCopy/XLN Online Installer/Certs/cacert.pem" ]
  [ -f "$cotton/launchCopy/installData/installData_app/XLN Online Installer/XLN Online Installer.version" ]
  [ -f "$cotton/launchCopy/installData/installData_app/XLN Online Installer/LuaSystem.xpak" ]
  [ "$(cat "$cotton/launchCopy/installData/installData_app/XLN Online Installer/XLN Online Installer.version")" = '4_7_3 Release1' ]
  [ ! -e "$cotton/launchCopy/updateBinary" ]
}

@test "sandbox launches the XLN updateBinary copy so chdir and argv use launchCopy" {
  load_sandbox
  configure_sandbox
  local cotton="$COPY/drive_c/ProgramData/XLN Audio/Temp/App/Cotton XLN Online Installer"
  local src="$cotton/updateBinary/XLN Online Installer.exe"
  local dest="$cotton/launchCopy/XLN Online Installer.exe"
  local rel="drive_c/ProgramData/XLN Audio/Temp/App/Cotton XLN Online Installer/updateBinary/installData/installData_app/cacert.pem"
  local launch_rel="drive_c/ProgramData/XLN Audio/Temp/App/Cotton XLN Online Installer/launchCopy/installData/installData_app/cacert.pem"
  local cache="$FIXTURE_ROOT/run-state/xln-cacert.pem"
  local win='C:\ProgramData\XLN Audio\Temp\App\Cotton XLN Online Installer\updateBinary\XLN Online Installer.exe'
  local staged='C:\ProgramData\XLN Audio\Temp\App\Cotton XLN Online Installer\launchCopy\XLN Online Installer.exe'
  seed_xln_updatebinary_tree "$cotton"
  sandbox_pin_xln_installer_cacert "$COPY"
  build_command fake-daw "$win"
  [ -f "$src" ]
  [ -f "$dest" ]
  [ "$(cat "$src")" = installer-image ]
  [ -f "$cotton/launchCopy/installData/installData_app/XLN Online Installer/LuaSystem.xpak" ]
  [ -s "$COPY/$launch_rel" ]
  assert_sequence --chdir "$cotton/launchCopy"
  assert_sequence -- "$FIXTURE_BIN/fake-daw" "$staged"
  refute_sequence -- "$FIXTURE_BIN/fake-daw" "$win"
  refute_sequence --chdir "$cotton/updateBinary"
  refute_sequence --ro-bind "$cotton/launchCopy"
  refute_sequence --ro-bind "$dest"
  refute_sequence --ro-bind "$src"
  assert_sequence --ro-bind "$cache" "$COPY/$rel"
  assert_sequence --ro-bind "$cache" "$COPY/$launch_rel"
}

@test "sandbox accepts a forward-slash XLN updateBinary installer path" {
  load_sandbox
  configure_sandbox
  local cotton="$COPY/drive_c/ProgramData/XLN Audio/Temp/App/Cotton XLN Online Installer"
  mkdir -p "$cotton/updateBinary"
  printf '%s\n' 'installer-image' > "$cotton/updateBinary/XLN Online Installer.exe"
  local staged
  staged="$(sandbox_xln_updatebinary_launch_arg "$COPY" \
    'c:/ProgramData/XLN Audio/Temp/App/Cotton XLN Online Installer/updateBinary/XLN Online Installer.exe')"
  [ "$staged" = 'c:\ProgramData\XLN Audio\Temp\App\Cotton XLN Online Installer\launchCopy\XLN Online Installer.exe' ]
  [ -f "$cotton/updateBinary/XLN Online Installer.exe" ]
  [ -f "$cotton/launchCopy/XLN Online Installer.exe" ]
}

@test "sandbox pin restores cacert next to an XLN launchCopy" {
  load_sandbox
  configure_sandbox
  local cotton="$COPY/drive_c/ProgramData/XLN Audio/Temp/App/Cotton XLN Online Installer"
  local certs="$COPY/drive_c/ProgramData/XLN Audio/XLN Online Installer/App/XLN Online Installer/Certs"
  mkdir -p "$certs" "$cotton/launchCopy/installData/installData_app"
  printf '%s\n' '-----BEGIN CERTIFICATE-----' 'MIIB' '-----END CERTIFICATE-----' > "$certs/cacert.pem"
  sandbox_pin_xln_installer_cacert "$COPY"
  [ -s "$cotton/launchCopy/XLN Online Installer/Certs/cacert.pem" ]
  grep -q 'BEGIN CERTIFICATE' "$cotton/launchCopy/XLN Online Installer/Certs/cacert.pem"
  [ -s "$cotton/launchCopy/installData/installData_app/cacert.pem" ]
  grep -q 'BEGIN CERTIFICATE' "$cotton/launchCopy/installData/installData_app/cacert.pem"
}

@test "sandbox syncs clone Program Files from updateBinary when hashes differ" {
  load_sandbox
  configure_sandbox
  local cotton="$COPY/drive_c/ProgramData/XLN Audio/Temp/App/Cotton XLN Online Installer"
  local pf="$COPY/drive_c/Program Files/XLN Audio/XLN Online Installer"
  seed_xln_updatebinary_tree "$cotton"
  mkdir -p "$pf/XLN Online Installer"
  printf '%s\n' 'old-4.7.2-exe' > "$pf/XLN Online Installer.exe"
  printf '%s\n' '4_7_2 Release1' > "$pf/XLN Online Installer/XLN Online Installer.version"
  sandbox_sync_xln_program_files_from_updatebinary "$COPY"
  [ "$(cat "$pf/XLN Online Installer.exe")" = installer-image ]
  [ "$(cat "$pf/XLN Online Installer/XLN Online Installer.version")" = '4_7_3 Release1' ]
  [ "$(cat "$pf/XLN Online Installer/LuaSystem.xpak")" = lua-system ]
  [ "$(cat "$cotton/updateBinary/XLN Online Installer.exe")" = installer-image ]
}

@test "sandbox sync of XLN Program Files is a no-op when hashes already match" {
  load_sandbox
  configure_sandbox
  local cotton="$COPY/drive_c/ProgramData/XLN Audio/Temp/App/Cotton XLN Online Installer"
  local pf="$COPY/drive_c/Program Files/XLN Audio/XLN Online Installer"
  seed_xln_updatebinary_tree "$cotton"
  mkdir -p "$pf/XLN Online Installer"
  cp -f -- "$cotton/updateBinary/XLN Online Installer.exe" "$pf/XLN Online Installer.exe"
  cp -f -- "$cotton/updateBinary/installData/installData_app/XLN Online Installer/XLN Online Installer.version" \
    "$pf/XLN Online Installer/XLN Online Installer.version"
  touch -d '2000-01-01 00:00:00' "$pf/XLN Online Installer.exe"
  local before
  before="$(stat -c '%Y' "$pf/XLN Online Installer.exe")"
  sandbox_sync_xln_program_files_from_updatebinary "$COPY"
  [ "$(cat "$pf/XLN Online Installer.exe")" = installer-image ]
  [ "$(stat -c '%Y' "$pf/XLN Online Installer.exe")" = "$before" ]
}

@test "sandbox sync of XLN Program Files never writes a path outside the clone" {
  load_sandbox
  configure_sandbox
  local cotton="$COPY/drive_c/ProgramData/XLN Audio/Temp/App/Cotton XLN Online Installer"
  local prod_pf="$REAL_PREFIX/drive_c/Program Files/XLN Audio/XLN Online Installer"
  local outside="$BATS_TEST_TMPDIR/outside-xln-pf"
  seed_xln_updatebinary_tree "$cotton"
  mkdir -p "$prod_pf" "$outside" "$COPY/drive_c/Program Files/XLN Audio"
  printf '%s\n' 'production-exe' > "$prod_pf/XLN Online Installer.exe"
  printf '%s\n' 'outside-exe' > "$outside/XLN Online Installer.exe"
  sandbox_sync_xln_program_files_from_updatebinary "$COPY"
  [ "$(cat "$prod_pf/XLN Online Installer.exe")" = production-exe ]
  [ ! -e "$COPY/drive_c/Program Files/XLN Audio/XLN Online Installer/XLN Online Installer.exe" ]
  ln -s "$outside" "$COPY/drive_c/Program Files/XLN Audio/XLN Online Installer"
  run sandbox_sync_xln_program_files_from_updatebinary "$COPY"
  [ "$status" -ne 0 ]
  [ "$(cat "$outside/XLN Online Installer.exe")" = outside-exe ]
  [ "$(cat "$prod_pf/XLN Online Installer.exe")" = production-exe ]
}

@test "launcher stages the XLN updateBinary installer to launchCopy on the clone" {
  local cotton_src="$REAL_PREFIX/drive_c/ProgramData/XLN Audio/Temp/App/Cotton XLN Online Installer"
  local cotton="$COPY/drive_c/ProgramData/XLN Audio/Temp/App/Cotton XLN Online Installer"
  seed_xln_updatebinary_tree "$cotton_src"

  run_daw_fixture --prefix "$REAL_PREFIX" fake-daw \
    'C:\ProgramData\XLN Audio\Temp\App\Cotton XLN Online Installer\updateBinary\XLN Online Installer.exe'

  [ "$status" -eq 0 ]
  [ -f "$cotton/updateBinary/XLN Online Installer.exe" ]
  [ -f "$cotton/launchCopy/XLN Online Installer.exe" ]
  [ -f "$cotton/launchCopy/installData/installData_app/XLN Online Installer/LuaSystem.xpak" ]
  [ "$(cat "$cotton/updateBinary/XLN Online Installer.exe")" = installer-image ]
  [ ! -e "$cotton/launchCopy/updateBinary" ]
  [ ! -e "$cotton_src/launchCopy" ]
  [[ "$(launched_argv)" == *launchCopy* ]]
  [[ "$(launched_argv)" == *"--chdir"* ]]
}

@test "launcher syncs clone Program Files from updateBinary and leaves production" {
  local cotton_src="$REAL_PREFIX/drive_c/ProgramData/XLN Audio/Temp/App/Cotton XLN Online Installer"
  local pf_src="$REAL_PREFIX/drive_c/Program Files/XLN Audio/XLN Online Installer"
  local pf="$COPY/drive_c/Program Files/XLN Audio/XLN Online Installer"
  seed_xln_updatebinary_tree "$cotton_src"
  mkdir -p "$pf_src"
  printf '%s\n' 'old-4.7.2-exe' > "$pf_src/XLN Online Installer.exe"

  run_daw_fixture --prefix "$REAL_PREFIX" fake-daw \
    'C:\ProgramData\XLN Audio\Temp\App\Cotton XLN Online Installer\updateBinary\XLN Online Installer.exe'

  [ "$status" -eq 0 ]
  [ "$(cat "$pf/XLN Online Installer.exe")" = installer-image ]
  [ "$(cat "$pf/XLN Online Installer/XLN Online Installer.version")" = '4_7_3 Release1' ]
  [ "$(cat "$pf_src/XLN Online Installer.exe")" = old-4.7.2-exe ]
}

@test "sandbox launches the synced Program Files installer instead of launchCopy" {
  load_sandbox
  configure_sandbox
  local cotton="$COPY/drive_c/ProgramData/XLN Audio/Temp/App/Cotton XLN Online Installer"
  local pf="$COPY/drive_c/Program Files/XLN Audio/XLN Online Installer"
  local win='C:\ProgramData\XLN Audio\Temp\App\Cotton XLN Online Installer\updateBinary\XLN Online Installer.exe'
  local staged='C:\Program Files\XLN Audio\XLN Online Installer\XLN Online Installer.exe'
  seed_xln_updatebinary_tree "$cotton"
  mkdir -p "$pf"
  printf '%s\n' 'old-4.7.2-exe' > "$pf/XLN Online Installer.exe"
  build_command fake-daw "$win"
  [ "$(cat "$pf/XLN Online Installer.exe")" = installer-image ]
  assert_sequence --chdir "$pf"
  assert_sequence -- "$FIXTURE_BIN/fake-daw" "$staged"
  refute_sequence --chdir "$cotton/launchCopy"
  refute_sequence -- "$FIXTURE_BIN/fake-daw" \
    'C:\ProgramData\XLN Audio\Temp\App\Cotton XLN Online Installer\launchCopy\XLN Online Installer.exe'
}

@test "sandbox repairs a half-updated XLN updateBinary from the Cotton bundle" {
  load_sandbox
  configure_sandbox
  local cotton="$COPY/drive_c/ProgramData/XLN Audio/Temp/App/Cotton XLN Online Installer"
  local src="$cotton/updateBinary/XLN Online Installer.exe"
  mkdir -p "$cotton/updateBinary"
  mkdir -p "$cotton/XLN Online Installer/installData/installData_app/XLN Online Installer"
  mkdir -p "$cotton/XLN Online Installer/installData/installData_prg"
  printf '%s\n' 'installer-image' > "$src"
  printf '%s\n' '4_7_3 Release1' > \
    "$cotton/XLN Online Installer/installData/installData_app/XLN Online Installer/XLN Online Installer.version"
  printf '%s\n' 'lua-system' > \
    "$cotton/XLN Online Installer/installData/installData_app/XLN Online Installer/LuaSystem.xpak"
  printf '%s\n' 'installer-image' > \
    "$cotton/XLN Online Installer/installData/installData_prg/XLN Online Installer.exe"
  local staged
  staged="$(sandbox_stage_xln_updatebinary_launch_copy "$COPY" \
    'C:\ProgramData\XLN Audio\Temp\App\Cotton XLN Online Installer\updateBinary\XLN Online Installer.exe')"
  [ "$staged" = 'C:\ProgramData\XLN Audio\Temp\App\Cotton XLN Online Installer\launchCopy\XLN Online Installer.exe' ]
  [ -f "$src" ]
  [ "$(cat "$src")" = installer-image ]
  [ -f "$cotton/updateBinary/installData/installData_app/XLN Online Installer/LuaSystem.xpak" ]
  [ -f "$cotton/launchCopy/installData/installData_app/XLN Online Installer/LuaSystem.xpak" ]
  [ "$(cat "$cotton/launchCopy/installData/installData_app/XLN Online Installer/XLN Online Installer.version")" = '4_7_3 Release1' ]
  [ ! -e "$cotton/launchCopy/updateBinary" ]
}

# ── Production paths stay, clone and isolated bridges overlay them ────────────
#
# Bitwig persists absolute plugin paths into ~/.BitwigStudio. The clone and
# isolated yabridge trees must therefore appear at the host paths Bitwig
# already indexed: the production prefix and the resolved ~/.vst/yabridge,
# ~/.vst3/yabridge, ~/.clap/yabridge directories. Symlink aliases stay
# symlinks so Bitwig still follows those path strings.
# Production directories stay read-only on the host; the overlay source is
# the clone or the isolated tree.

@test "sandbox overlays the clone over the production prefix path" {
  load_sandbox
  configure_sandbox

  build_command fake-daw

  assert_sequence --bind "$COPY" "$REAL_PREFIX"
  assert_sequence --bind "$COPY" "$COPY"
  assert_sequence --setenv WINEPREFIX "$REAL_PREFIX"
  refute_sequence --ro-bind "$REAL_PREFIX" "$REAL_PREFIX"
  refute_sequence --bind "$REAL_PREFIX" "$REAL_PREFIX"
  assert_writable "$REAL_PREFIX"
  assert_writable "$REAL_PREFIX/drive_c/production.txt"
  assert_writable "$COPY"
  assert_writable "$COPY/drive_c"
}

@test "sandbox overlays the clone over a winplugins alias of the prefix" {
  load_sandbox
  ln -s "$REAL_PREFIX" "$PRODUCTION_HOME/winplugins"
  configure_sandbox

  build_command fake-daw

  assert_sequence --bind "$COPY" "$REAL_PREFIX"
  refute_sequence --bind "$COPY" "$PRODUCTION_HOME/winplugins"
  refute_sequence --bind "$REAL_PREFIX" "$PRODUCTION_HOME/winplugins"
  refute_symlink_mount_destinations
}

@test "sandbox mounts production plugin roots read-only outside yabridge" {
  load_sandbox
  configure_sandbox

  build_command fake-daw

  local plugin_root
  for plugin_root in .vst .vst3 .clap; do
    assert_sequence --ro-bind "$PRODUCTION_HOME/$plugin_root" \
      "$PRODUCTION_HOME/$plugin_root"
    assert_read_only "$PRODUCTION_HOME/$plugin_root"
  done
}

@test "sandbox overlays isolated yabridge over production plugin paths" {
  load_sandbox
  configure_sandbox

  build_command fake-daw

  local plugin_root
  for plugin_root in .vst .vst3 .clap; do
    assert_sequence --bind "$ISOLATED_HOME/$plugin_root/yabridge" \
      "$PRODUCTION_HOME/$plugin_root/yabridge"
    refute_sequence --bind "$PRODUCTION_HOME/$plugin_root/yabridge" \
      "$PRODUCTION_HOME/$plugin_root/yabridge"
    assert_writable "$PRODUCTION_HOME/$plugin_root/yabridge"
  done
}

@test "sandbox hides isolated plugin roots so they cannot be reindexed" {
  load_sandbox
  configure_sandbox

  build_command fake-daw

  local plugin_root
  for plugin_root in .vst .vst3 .clap; do
    assert_sequence --tmpfs "$ISOLATED_HOME/$plugin_root"
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
  refute_sequence --ro-bind "$target" "$PRODUCTION_HOME/.vst"
  refute_sequence --bind "$ISOLATED_HOME/.vst/yabridge" \
    "$PRODUCTION_HOME/.vst/yabridge"
  refute_sequence --bind "$target" "$target"
  refute_symlink_mount_destinations
  assert_read_only "$target"
  assert_sequence --bind "$ISOLATED_HOME/.vst/yabridge" "$target/yabridge"
  assert_writable "$target/yabridge"
  assert_writable "$PRODUCTION_HOME/.vst/yabridge"
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
  refute_sequence --ro-bind "$target" "$PRODUCTION_HOME/.vst"
  refute_sequence --ro-bind "$target" "$PRODUCTION_HOME/.vst3"
  refute_symlink_mount_destinations
  assert_read_only "$target"
}

# HOME/.vst is often a symlink (here, into .audio-production). bwrap refuses
# "Can't mount on symlink destination". Overlay the resolved directory; keep
# the lexical ~/.vst/yabridge string for Bitwig's plugin list.
@test "sandbox never mounts onto a symlinked plugin root" {
  load_sandbox
  local vst_target="$BATS_TEST_TMPDIR/audio-production/.vst"
  local vst3_target="$BATS_TEST_TMPDIR/audio-production/.vst3"
  local clap_target="$BATS_TEST_TMPDIR/audio-production/.clap"
  alias_plugin_root .vst "$vst_target"
  alias_plugin_root .vst3 "$vst3_target"
  alias_plugin_root .clap "$clap_target"
  configure_sandbox

  build_command fake-daw

  local name target
  for name in .vst .vst3 .clap; do
    case "$name" in
      .vst) target="$vst_target" ;;
      .vst3) target="$vst3_target" ;;
      .clap) target="$clap_target" ;;
    esac
    refute_sequence --ro-bind "$target" "$PRODUCTION_HOME/$name"
    refute_sequence --bind "$ISOLATED_HOME/$name/yabridge" \
      "$PRODUCTION_HOME/$name/yabridge"
    refute_sequence --tmpfs "$PRODUCTION_HOME/$name"
    assert_sequence --ro-bind "$target" "$target"
    assert_sequence --bind "$ISOLATED_HOME/$name/yabridge" "$target/yabridge"
    assert_writable "$target/yabridge"
    assert_writable "$PRODUCTION_HOME/$name/yabridge"
  done
  refute_symlink_mount_destinations
}

@test "sandbox binds the host home as the DAW HOME" {
  load_sandbox
  configure_sandbox

  build_command fake-daw

  assert_sequence --bind "$PRODUCTION_HOME" "$PRODUCTION_HOME"
  assert_writable "$PRODUCTION_HOME"
  assert_writable "$PRODUCTION_HOME/.BitwigStudio"
  refute_sequence --ro-bind "$PRODUCTION_HOME" "$PRODUCTION_HOME"
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

@test "sandbox exports the host home; XDG stays isolated for yabridge" {
  load_sandbox
  configure_sandbox

  build_command fake-daw

  assert_sequence --setenv HOME "$PRODUCTION_HOME"
  assert_sequence --setenv USER "$(id -un)"
  assert_sequence --setenv XDG_CONFIG_HOME "$ISOLATED_HOME/.config"
  assert_sequence --setenv XDG_DATA_HOME "$ISOLATED_HOME/.local/share"
  assert_sequence --setenv XDG_RUNTIME_DIR "$RUNTIME_DESTINATION"
  assert_sequence --uid "$(id -u)"
  assert_sequence --gid "$(id -g)"
  refute_sequence --setenv HOME "$ISOLATED_HOME"
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
  assert_writable "$PRODUCTION_HOME/private-notes"
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
  assert_writable "$PRODUCTION_HOME/.local/share/keys/token"
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
  assert_writable "$PRODUCTION_HOME/opt/Studio/lib/libstudio.so"
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

@test "sandbox refuses to plan a mount onto a symlink destination" {
  load_sandbox
  configure_sandbox
  local link="$BATS_TEST_TMPDIR/symlink-dest"
  ln -s "$PROJECTS" "$link"
  SANDBOX_MOUNT_DESTINATIONS=()
  SANDBOX_MOUNT_ARGUMENTS=()

  run sandbox_add_mount --bind "$PROJECTS" "$link"

  [ "$status" -ne 0 ]
  [[ "$output" == *"symlink"* ]]
}

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

# ── XLN / MAC identity (unshare user+net we own, then pasta, then bwrap) ────
#
# Firejail+nsenter is a dead end unprivileged: Firejail's netns lives in its
# own user namespace and cannot be joined without caps in the initial userns.
# Firejail as a parent also replaces bwrap with fbwrap; firejail inside bwrap
# drops --mac. The working path creates user+net namespaces we own, starts
# pasta (or slirp4netns) from the host attached to that netns, then runs
# real bwrap inside it (no --unshare-net).

write_fake_firejail() {
  local path="${1:-$FIXTURE_BIN/firejail}"
  cat > "$path" <<'EOF'
#!/bin/bash
{
  printf 'argv'
  printf ' %q' "$@"
  printf '\n'
} >> "${SANDBOX_TEST_FIREJAIL_CALLS:?}"
if [[ "${SANDBOX_TEST_FIREJAIL_FAIL:-false}" == true ]]; then
  printf 'Error: firejail refused to start\n' >&2
  exit 1
fi
separator=false
declare -a child=()
while [[ $# -gt 0 ]]; do
  if [[ "$separator" == true ]]; then
    child+=("$1")
    shift
    continue
  fi
  if [[ "$1" == -- ]]; then
    separator=true
    shift
    continue
  fi
  shift
done
if [[ "$separator" != true || "${#child[@]}" -eq 0 ]]; then
  printf 'firejail: no command to execute\n' >&2
  exit 1
fi
exec "${child[@]}"
EOF
  chmod +x "$path"
}

# Records unshare flags, then execs the remaining program in this process
# (no real namespace). The helper therefore runs and can start fake pasta.
write_fake_unshare() {
  local path="${1:-$FIXTURE_BIN/unshare}"
  cat > "$path" <<'EOF'
#!/bin/bash
{
  printf 'argv'
  printf ' %q' "$@"
  printf '\n'
} >> "${SANDBOX_TEST_UNSHARE_CALLS:?}"
if [[ "${SANDBOX_TEST_UNSHARE_FAIL:-false}" == true ]]; then
  printf 'unshare: failed to unshare namespaces\n' >&2
  exit 1
fi
while [[ $# -gt 0 ]]; do
  case "$1" in
    --)
      shift
      break
      ;;
    --user|--map-root-user|--net|-r|-n|-U|-m|-p|-i|-u|-C|-T|-f)
      shift
      ;;
    --user=*|--net=*|--map-user=*|--map-group=*|--setuid=*|--setgid=*)
      shift
      ;;
    --map-user|--map-group|--setuid|--setgid|--kill-child|--root|--wd)
      shift 2
      ;;
    -*)
      shift
      ;;
    *)
      break
      ;;
  esac
done
if [[ $# -eq 0 ]]; then
  printf 'unshare: no command to execute\n' >&2
  exit 1
fi
exec "$@"
EOF
  chmod +x "$path"
}

write_fake_pasta() {
  local path="${1:-$FIXTURE_BIN/pasta}"
  cat > "$path" <<'EOF'
#!/bin/bash
{
  printf 'argv0 %q' "$(basename -- "$0")"
  printf ' %q' "$@"
  printf '\n'
} >> "${SANDBOX_TEST_PASTA_CALLS:?}"
if [[ "${SANDBOX_TEST_PASTA_FAIL:-false}" == true ]]; then
  printf 'pasta: failed to configure network\n' >&2
  exit 1
fi
mac=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mac-addr)
      mac="${2:-}"
      shift 2
      ;;
    --mac-addr=*)
      mac="${1#--mac-addr=}"
      shift
      ;;
    *)
      shift
      ;;
  esac
done
sysfs="${SANDBOX_NIC_SYSFS:-/sys/class/net}"
if [[ -n "$mac" ]]; then
  mkdir -p "$sysfs/pasta0"
  printf '%s\n' "${mac,,}" > "$sysfs/pasta0/address"
fi
if [[ -n "${SANDBOX_TEST_PASTA_PIDS:-}" ]]; then
  printf '%s\n' "$$" >> "$SANDBOX_TEST_PASTA_PIDS"
fi
exec /bin/sleep infinity
EOF
  chmod +x "$path"
}

write_fake_slirp4netns() {
  local path="${1:-$FIXTURE_BIN/slirp4netns}"
  cat > "$path" <<'EOF'
#!/bin/bash
{
  printf 'argv'
  printf ' %q' "$@"
  printf '\n'
} >> "${SANDBOX_TEST_SLIRP_CALLS:?}"
if [[ "${SANDBOX_TEST_SLIRP_FAIL:-false}" == true ]]; then
  printf 'slirp4netns: failed to configure tap\n' >&2
  exit 1
fi
mac=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mac-addr)
      mac="${2:-}"
      shift 2
      ;;
    --mac-addr=*)
      mac="${1#--mac-addr=}"
      shift
      ;;
    *)
      shift
      ;;
  esac
done
sysfs="${SANDBOX_NIC_SYSFS:-/sys/class/net}"
if [[ -n "$mac" ]]; then
  mkdir -p "$sysfs/tap0"
  printf '%s\n' "${mac,,}" > "$sysfs/tap0/address"
fi
if [[ -n "${SANDBOX_TEST_PASTA_PIDS:-}" ]]; then
  printf '%s\n' "$$" >> "$SANDBOX_TEST_PASTA_PIDS"
fi
exec /bin/sleep infinity
EOF
  chmod +x "$path"
}

launched_unshare_argv() {
  if [[ ! -f "$UNSHARE_CALLS" ]]; then
    printf '\n'
    return 0
  fi
  cat "$UNSHARE_CALLS"
}

launched_pasta_argv() {
  if [[ ! -f "$PASTA_CALLS" ]]; then
    printf '\n'
    return 0
  fi
  cat "$PASTA_CALLS"
}

launched_slirp_argv() {
  if [[ ! -f "$SLIRP_CALLS" ]]; then
    printf '\n'
    return 0
  fi
  cat "$SLIRP_CALLS"
}

launched_firejail_argv() {
  if [[ ! -f "${FIREJAIL_CALLS:-}" ]]; then
    printf '\n'
    return 0
  fi
  cat "$FIREJAIL_CALLS"
}

setup_mac_identity_fixtures() {
  NIC_SYSFS="$BATS_TEST_TMPDIR/sys-class-net"
  mkdir -p "$NIC_SYSFS/eno1" "$NIC_SYSFS/lo"
  export SANDBOX_NIC_SYSFS="$NIC_SYSFS"
  # The launcher derives the NIC default from the host's default route; pin
  # it so fixtures do not depend on the machine running the tests.
  export SANDBOX_DEFAULT_NIC="eno1"
  UNSHARE_CALLS="$BATS_TEST_TMPDIR/unshare.calls"
  : > "$UNSHARE_CALLS"
  export SANDBOX_TEST_UNSHARE_CALLS="$UNSHARE_CALLS"
  PASTA_CALLS="$BATS_TEST_TMPDIR/pasta.calls"
  : > "$PASTA_CALLS"
  export SANDBOX_TEST_PASTA_CALLS="$PASTA_CALLS"
  SLIRP_CALLS="$BATS_TEST_TMPDIR/slirp.calls"
  : > "$SLIRP_CALLS"
  export SANDBOX_TEST_SLIRP_CALLS="$SLIRP_CALLS"
  FIREJAIL_CALLS="$BATS_TEST_TMPDIR/firejail.calls"
  : > "$FIREJAIL_CALLS"
  export SANDBOX_TEST_FIREJAIL_CALLS="$FIREJAIL_CALLS"
  PASTA_PIDS="$BATS_TEST_TMPDIR/pasta.pids"
  : > "$PASTA_PIDS"
  export SANDBOX_TEST_PASTA_PIDS="$PASTA_PIDS"
  write_fake_unshare
  write_fake_pasta
  write_fake_slirp4netns
}

@test "MAC identity rejects malformed addresses and unsafe NIC names" {
  load_sandbox
  SANDBOX_NIC_SYSFS="$BATS_TEST_TMPDIR/sys-class-net"
  mkdir -p "$SANDBOX_NIC_SYSFS/eno1"

  run validate_sandbox_mac "02:00:5e:00:53:01"
  [ "$status" -eq 0 ]
  run validate_sandbox_mac "02:DE:AD:BE:EF:01"
  [ "$status" -eq 0 ]
  run validate_sandbox_mac "not-a-mac"
  [ "$status" -ne 0 ]
  run validate_sandbox_mac "--mac"
  [ "$status" -ne 0 ]
  run validate_sandbox_mac ""
  [ "$status" -ne 0 ]

  run validate_sandbox_nic "eno1"
  [ "$status" -eq 0 ]
  run validate_sandbox_nic "../eno1"
  [ "$status" -ne 0 ]
  run validate_sandbox_nic "missing0"
  [ "$status" -ne 0 ]
  run validate_sandbox_nic "--net"
  [ "$status" -ne 0 ]

  run validate_sandbox_address "192.0.2.132"
  [ "$status" -eq 0 ]
  run validate_sandbox_address "192.0.2.132/24"
  [ "$status" -eq 0 ]
  run validate_sandbox_address "10.0.0.1"
  [ "$status" -eq 0 ]
  run validate_sandbox_address ""
  [ "$status" -ne 0 ]
  run validate_sandbox_address "--address"
  [ "$status" -ne 0 ]
  run validate_sandbox_address "not-an-ip"
  [ "$status" -ne 0 ]
  run validate_sandbox_address "192.168.1.256"
  [ "$status" -ne 0 ]
  run validate_sandbox_address "192.0.2.132/33"
  [ "$status" -ne 0 ]
}

@test "xln-fj is recognized as an identity wrapper" {
  load_sandbox

  run sandbox_is_xln_identity_wrapper "/home/user/.local/bin/xln-fj"
  [ "$status" -eq 0 ]
  run sandbox_is_xln_identity_wrapper "/opt/bitwig-studio/bitwig-studio"
  [ "$status" -ne 0 ]
  run sandbox_is_xln_identity_wrapper "/usr/bin/firejail"
  [ "$status" -ne 0 ]
}

@test "MAC identity wraps bwrap with unshare user+net and pasta, not nsenter" {
  load_sandbox
  configure_sandbox
  setup_mac_identity_fixtures
  SANDBOX_NETWORK=true
  SANDBOX_MAC="02:00:5e:00:53:01"
  SANDBOX_NIC="eno1"
  require_unshare
  require_mac_netns_backend

  build_command fake-daw
  WRAPPED_COMMAND=()
  wrap_launch_with_mac_identity WRAPPED_COMMAND SANDBOX_COMMAND

  [ "${WRAPPED_COMMAND[0]}" = "$SANDBOX_MAC_NETNS_EXEC" ]
  [ "${SANDBOX_COMMAND[0]}" = "$SANDBOX_BWRAP" ]
  [ "$SANDBOX_MAC_BACKEND" = pasta ]
  [[ " ${WRAPPED_COMMAND[*]} " == *" --mac 02:00:5e:00:53:01 "* ]]
  [[ " ${WRAPPED_COMMAND[*]} " == *" --nic eno1 "* ]]
  [[ " ${WRAPPED_COMMAND[*]} " == *" --backend pasta "* ]]
  [[ " ${WRAPPED_COMMAND[*]} " == *" --unshare $SANDBOX_UNSHARE "* ]]
  [[ " ${WRAPPED_COMMAND[*]} " == *" $SANDBOX_BWRAP "* ]]
  refute_wrapped_token nsenter
  refute_wrapped_token firejail
  refute_sequence --unshare-net
}

# The wrap only builds argv. The helper creates the netns, starts pasta from
# the host (so it still sees host routes), then execs bwrap in that netns.
@test "MAC identity never puts bwrap under firejail or nsenter" {
  load_sandbox
  configure_sandbox
  setup_mac_identity_fixtures
  SANDBOX_NETWORK=true
  SANDBOX_MAC="02:00:5e:00:53:01"
  SANDBOX_NIC="eno1"
  require_unshare
  require_mac_netns_backend

  build_command fake-daw
  [ "${#SANDBOX_COMMAND[@]}" -gt 40 ]
  [ "${SANDBOX_COMMAND[0]}" = "$SANDBOX_BWRAP" ]

  WRAPPED_COMMAND=()
  wrap_launch_with_mac_identity WRAPPED_COMMAND SANDBOX_COMMAND

  [ "${WRAPPED_COMMAND[0]}" = "$SANDBOX_MAC_NETNS_EXEC" ]
  local token
  for token in "${WRAPPED_COMMAND[@]}"; do
    [[ "$token" != *nsenter* ]]
    [[ "$token" != *firejail* ]]
    [[ "$token" != --net=* ]]
  done
  [[ " ${WRAPPED_COMMAND[*]} " == *" $SANDBOX_BWRAP "* ]]
}

@test "MAC identity helper starts pasta then runs bwrap from the same netns" {
  load_sandbox
  configure_sandbox
  setup_mac_identity_fixtures
  SANDBOX_NETWORK=true
  SANDBOX_MAC="02:00:5e:00:53:01"
  SANDBOX_NIC="eno1"
  require_unshare
  require_mac_netns_backend

  build_command fake-daw
  WRAPPED_COMMAND=()
  wrap_launch_with_mac_identity WRAPPED_COMMAND SANDBOX_COMMAND

  run "${WRAPPED_COMMAND[@]}"

  [ "$status" -eq 0 ]
  [[ "$(launched_unshare_argv)" == *" --user "* ]]
  [[ "$(launched_unshare_argv)" == *" --map-root-user "* ]]
  [[ "$(launched_unshare_argv)" == *" --net "* ]]
  [[ "$(launched_pasta_argv)" == argv0\ pasta\ * ]]
  [[ "$(launched_pasta_argv)" == *" --config-net "* ]]
  [[ "$(launched_pasta_argv)" == *" --foreground "* ]]
  [[ "$(launched_pasta_argv)" == *" --userns "* ]]
  [[ "$(launched_pasta_argv)" == *" --netns "* ]]
  [[ "$(launched_pasta_argv)" =~ /proc/[0-9]+/ns/user ]]
  [[ "$(launched_pasta_argv)" =~ /proc/[0-9]+/ns/net ]]
  [[ "$(launched_pasta_argv)" != *"/proc/self/ns/net"* ]]
  [[ "$(launched_pasta_argv)" == *" --mac-addr "* ]]
  [[ "$(launched_pasta_argv)" == *" --ns-mac-addr "* ]]
  [[ "$(launched_pasta_argv)" == *"02:00:5e:00:53:01"* ]]
  [[ "$(launched_pasta_argv)" == *" --ns-ifname "* ]]
  [[ "$(launched_pasta_argv)" == *" eth0 "* ]]
  [[ "$(launched_pasta_argv)" == *" --interface "* ]]
  [[ "$(launched_pasta_argv)" == *"eno1"* ]]
  [[ "$(launched_pasta_argv)" == *" --outbound-if4 "* ]]
  [[ "$(launched_pasta_argv)" == *" --dns "* ]]
  [[ "$(launched_pasta_argv)" == *"1.1.1.1"* ]]
  [[ "$(launched_pasta_argv)" == *"192.168.1.1"* ]]
  [[ "$(launched_pasta_argv)" == *" --dhcp-dns"* ]]
  [[ "$(launched_pasta_argv)" != *" --address "* ]]
  [[ "$(launched_pasta_argv)" != argv0\ passt* ]]
  [ -f "$DAW_ENV_FILE" ]
  [ "$(daw_env_value WINEPREFIX)" = "$REAL_PREFIX" ]
  [ -s "$PASTA_PIDS" ]
  local leftover
  leftover="$(cat "$PASTA_PIDS")"
  [ -n "$leftover" ]
  ! kill -0 "$leftover" 2>/dev/null
}

@test "MAC identity helper pins the pasta guest IPv4 when --address is set" {
  load_sandbox
  configure_sandbox
  setup_mac_identity_fixtures
  SANDBOX_NETWORK=true
  SANDBOX_MAC="02:00:5e:00:53:01"
  SANDBOX_NIC="eno1"
  SANDBOX_ADDRESS="192.0.2.132"
  require_unshare
  require_mac_netns_backend

  build_command fake-daw
  WRAPPED_COMMAND=()
  wrap_launch_with_mac_identity WRAPPED_COMMAND SANDBOX_COMMAND

  [[ " ${WRAPPED_COMMAND[*]} " == *" --address 192.0.2.132 "* ]]

  run "${WRAPPED_COMMAND[@]}"

  [ "$status" -eq 0 ]
  [[ "$(launched_pasta_argv)" == argv0\ pasta\ * ]]
  [[ "$(launched_pasta_argv)" == *" --config-net "* ]]
  [[ "$(launched_pasta_argv)" == *" --address "* ]]
  [[ "$(launched_pasta_argv)" == *"192.0.2.132"* ]]
  [[ "$(launched_pasta_argv)" == *" --ns-ifname "* ]]
  [[ "$(launched_pasta_argv)" == *" eth0 "* ]]
  [[ "$(launched_pasta_argv)" == *" --mac-addr "* ]]
  [[ "$(launched_pasta_argv)" == *"02:00:5e:00:53:01"* ]]
  [[ "$(launched_pasta_argv)" != argv0\ passt* ]]
}

# realpath(/usr/bin/pasta) is /usr/bin/passt; passt rejects --config-net.
# The helper must force pasta mode (argv0 pasta), not exec the passt path bare.
@test "MAC identity helper starts pasta mode when the binary path is passt" {
  load_sandbox
  configure_sandbox
  setup_mac_identity_fixtures
  write_fake_pasta "$FIXTURE_BIN/passt"
  SANDBOX_NETWORK=true
  SANDBOX_MAC="02:00:5e:00:53:01"
  SANDBOX_NIC="eno1"
  require_unshare
  require_mac_netns_backend
  SANDBOX_PASTA="$FIXTURE_BIN/passt"
  SANDBOX_MAC_BACKEND=pasta

  build_command fake-daw
  WRAPPED_COMMAND=()
  wrap_launch_with_mac_identity WRAPPED_COMMAND SANDBOX_COMMAND

  run "${WRAPPED_COMMAND[@]}"

  [ "$status" -eq 0 ]
  [[ "$(launched_pasta_argv)" == argv0\ pasta\ * ]]
  [[ "$(launched_pasta_argv)" == *" --config-net "* ]]
  [[ "$(launched_pasta_argv)" == *" --mac-addr "* ]]
  [[ "$(launched_pasta_argv)" == *"02:00:5e:00:53:01"* ]]
  [[ "$(launched_pasta_argv)" != argv0\ passt* ]]
  [[ "$(launched_pasta_argv)" != *"/passt "* ]]
}

@test "MAC identity refuses to wrap when the sandbox would unshare the network" {
  load_sandbox
  configure_sandbox
  setup_mac_identity_fixtures
  SANDBOX_NETWORK=false
  SANDBOX_MAC="02:00:5e:00:53:01"
  SANDBOX_NIC="eno1"
  require_unshare
  require_mac_netns_backend
  build_command fake-daw

  run wrap_launch_with_mac_identity WRAPPED_COMMAND SANDBOX_COMMAND

  [ "$status" -ne 0 ]
  [[ "$output" == *"network"* ]]
}

@test "require_unshare refuses when unshare is absent" {
  load_sandbox
  mkdir -p "$BATS_TEST_TMPDIR/empty-bin"
  local saved_path="$PATH"
  export PATH="$BATS_TEST_TMPDIR/empty-bin"

  run require_unshare

  export PATH="$saved_path"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unshare"* ]]
}

@test "require_mac_netns_backend refuses when pasta and slirp4netns are absent" {
  load_sandbox
  mkdir -p "$BATS_TEST_TMPDIR/empty-bin"
  local saved_path="$PATH"
  export PATH="$BATS_TEST_TMPDIR/empty-bin"

  run require_mac_netns_backend

  export PATH="$saved_path"
  [ "$status" -ne 0 ]
  [[ "$output" == *"pasta"* || "$output" == *"passt"* ]]
  [[ "$output" == *"slirp4netns"* ]]
}

@test "MAC identity falls back to slirp4netns when pasta is absent" {
  load_sandbox
  configure_sandbox
  setup_mac_identity_fixtures
  rm -f "$FIXTURE_BIN/pasta"
  if command -v pasta >/dev/null 2>&1; then
    skip "host pasta is installed; cannot observe slirp fallback"
  fi
  SANDBOX_NETWORK=true
  SANDBOX_MAC="02:00:5e:00:53:01"
  SANDBOX_NIC="eno1"
  require_unshare
  require_mac_netns_backend

  [ "$SANDBOX_MAC_BACKEND" = slirp4netns ]

  build_command fake-daw
  WRAPPED_COMMAND=()
  wrap_launch_with_mac_identity WRAPPED_COMMAND SANDBOX_COMMAND

  [[ " ${WRAPPED_COMMAND[*]} " == *" --backend slirp4netns "* ]]
  run "${WRAPPED_COMMAND[@]}"
  [ "$status" -eq 0 ]
  [[ "$(launched_slirp_argv)" == *" --mac-addr "* ]]
  [[ "$(launched_slirp_argv)" == *"02:00:5e:00:53:01"* ]]
  [ -f "$DAW_ENV_FILE" ]
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

# Bitwig looks at $HOME/.BitwigStudio and Java user.home from getpwuid.
# Remapping individual dirs into isolation/home failed twice: the DAW still
# used isolated HOME, then --mac mapped uid 0 and Bitwig opened
# /root/.BitwigStudio. HOME is the real login home; leftover first-run
# files under isolation/home/.BitwigStudio must not win.

@test "sandbox keeps DAW HOME on the host home when the process HOME is already isolated" {
  load_sandbox
  configure_sandbox
  mkdir -p "$PRODUCTION_HOME/.BitwigStudio" "$ISOLATED_HOME/.BitwigStudio"
  printf '%s\n' 'license' > "$PRODUCTION_HOME/.BitwigStudio/.eula-agreed"
  printf '%s\n' 'first-run' > "$ISOLATED_HOME/.BitwigStudio/.eula-agreed"
  SANDBOX_HOST_HOME="$PRODUCTION_HOME"
  HOME="$ISOLATED_HOME"

  build_command fake-daw

  HOME="$PRODUCTION_HOME"
  assert_sequence --setenv HOME "$PRODUCTION_HOME"
  assert_sequence --bind "$PRODUCTION_HOME" "$PRODUCTION_HOME"
  assert_writable "$PRODUCTION_HOME/.BitwigStudio"
  refute_sequence --setenv HOME "$ISOLATED_HOME"
  refute_sequence --bind "$PRODUCTION_HOME/.BitwigStudio" \
    "$ISOLATED_HOME/.BitwigStudio"
}

@test "sandbox does not remap a writable path into the isolated home" {
  load_sandbox
  configure_sandbox
  local bitwig="$PRODUCTION_HOME/.BitwigStudio"
  mkdir -p "$bitwig"
  printf '%s\n' 'license' > "$bitwig/.eula-agreed"
  SANDBOX_WRITABLE_PATHS=("$bitwig")

  build_command fake-daw

  assert_sequence --setenv HOME "$PRODUCTION_HOME"
  assert_writable "$bitwig"
  refute_sequence --bind "$bitwig" "$ISOLATED_HOME/.BitwigStudio"
  [ ! -d "$ISOLATED_HOME/.BitwigStudio" ]
}

@test "sandbox still binds a writable path outside the real home" {
  load_sandbox
  configure_sandbox
  SANDBOX_WRITABLE_PATHS=("$PROJECTS")

  build_command fake-daw

  assert_sequence --bind "$PROJECTS" "$PROJECTS"
  refute_sequence --bind "$PROJECTS" "$ISOLATED_HOME/projects"
}

@test "sandbox does not invent a missing Bitwig config directory" {
  load_sandbox
  configure_sandbox

  build_command fake-daw

  [ ! -e "$PRODUCTION_HOME/.BitwigStudio" ]
  [ ! -e "$ISOLATED_HOME/.BitwigStudio" ]
  refute_sequence --bind "$PRODUCTION_HOME/.BitwigStudio" \
    "$PRODUCTION_HOME/.BitwigStudio"
  refute_sequence --bind "$PRODUCTION_HOME/.BitwigStudio" \
    "$ISOLATED_HOME/.BitwigStudio"
}

@test "host home bind does not make the production prefix writable" {
  load_sandbox
  configure_sandbox
  mkdir -p "$PRODUCTION_HOME/.BitwigStudio"

  build_command fake-daw

  refute_sequence --bind "$REAL_PREFIX" "$REAL_PREFIX"
  assert_sequence --bind "$COPY" "$REAL_PREFIX"
  assert_writable "$PRODUCTION_HOME/.BitwigStudio"
}

@test "sandbox overlays passwd so uid 0 and the login uid have the host home" {
  load_sandbox
  configure_sandbox

  build_command fake-daw

  local identity="$ISOLATION/sandbox-identity"
  [ -f "$identity/passwd" ]
  [ -f "$identity/nsswitch.conf" ]
  awk -F: -v home="$PRODUCTION_HOME" '$3 == 0 && $6 == home { found = 1 }
    END { exit !found }' "$identity/passwd"
  awk -F: -v home="$PRODUCTION_HOME" -v uid="$(id -u)" \
    '$3 == uid && $6 == home { found = 1 } END { exit !found }' \
    "$identity/passwd"
  grep -Fxq 'passwd: files' "$identity/nsswitch.conf"
  assert_sequence --ro-bind "$identity/passwd" /etc/passwd
  assert_sequence --ro-bind "$identity/nsswitch.conf" /etc/nsswitch.conf
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

@test "sandbox binds an existing X authority file read-only" {
  load_sandbox
  configure_sandbox
  printf '%s\n' 'cookie' > "$PRODUCTION_HOME/.Xauthority"
  export XAUTHORITY="$PRODUCTION_HOME/.Xauthority"

  build_command fake-daw

  assert_sequence --ro-bind "$PRODUCTION_HOME/.Xauthority" \
    "$PRODUCTION_HOME/.Xauthority"
  assert_read_only "$PRODUCTION_HOME/.Xauthority"
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
  [[ "$(launched_argv)" == *" --bind $COPY $REAL_PREFIX "* ]]
  [[ "$(launched_argv)" == *" --bind $COPY $COPY "* ]]
  [ "$(daw_env_value HOME)" = "$PRODUCTION_HOME" ]
  [ "$(daw_env_value WINEPREFIX)" = "$REAL_PREFIX" ]
  [ "$(daw_env_value VST_PATH)" = "$PRODUCTION_HOME/.vst/yabridge" ]
  refute grep -Fq "$ISOLATED_HOME/.vst/yabridge" "$DAW_ENV_FILE"
}

@test "launcher keeps lexical plugin paths when ~/.vst is a symlink" {
  local target="$BATS_TEST_TMPDIR/audio-production/.vst"
  alias_plugin_root .vst "$target"
  ln -s "$REAL_PREFIX" "$PRODUCTION_HOME/winplugins"

  run_daw_fixture --prefix "$REAL_PREFIX" fake-daw

  [ "$status" -eq 0 ]
  [ "$(daw_env_value HOME)" = "$PRODUCTION_HOME" ]
  [ "$(daw_env_value VST_PATH)" = "$PRODUCTION_HOME/.vst/yabridge" ]
  [ "$(daw_env_value VST3_PATH)" = "$PRODUCTION_HOME/.vst3/yabridge" ]
  [ "$(daw_env_value CLAP_PATH)" = "$PRODUCTION_HOME/.clap/yabridge" ]
  [[ "$(launched_argv)" != *" --ro-bind $target $PRODUCTION_HOME/.vst "* ]]
  [[ "$(launched_argv)" != *" --bind $COPY $PRODUCTION_HOME/winplugins "* ]]
  [[ "$(launched_argv)" == *" --bind $ISOLATED_HOME/.vst/yabridge $target/yabridge "* ]]
  [[ "$(launched_argv)" == *" --bind $COPY $REAL_PREFIX "* ]]
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

@test "launcher applies MAC identity outside bwrap and still launches the DAW" {
  setup_mac_identity_fixtures

  run_daw_fixture --mac 02:00:5e:00:53:01 --nic eno1 --prefix "$REAL_PREFIX" \
    fake-daw

  [ "$status" -eq 0 ]
  [[ "$(launched_unshare_argv)" == *" --user "* ]]
  [[ "$(launched_unshare_argv)" == *" --map-root-user "* ]]
  [[ "$(launched_unshare_argv)" == *" --net "* ]]
  [[ "$(launched_pasta_argv)" == argv0\ pasta\ * ]]
  [[ "$(launched_pasta_argv)" == *" --config-net "* ]]
  [[ "$(launched_pasta_argv)" == *" --mac-addr "* ]]
  [[ "$(launched_pasta_argv)" == *"02:00:5e:00:53:01"* ]]
  [[ "$(launched_pasta_argv)" == *" --ns-ifname "* ]]
  [[ "$(launched_pasta_argv)" == *" eth0 "* ]]
  [[ "$(launched_pasta_argv)" == *" --interface "* ]]
  [[ "$(launched_pasta_argv)" == *"eno1"* ]]
  [[ "$(launched_pasta_argv)" != argv0\ passt* ]]
  [[ "$(launched_argv)" != *" --unshare-net "* ]]
  [[ "$(launched_argv)" == *" -- $FIXTURE_BIN/fake-daw"* ]]
  [ "$(daw_env_value WINEPREFIX)" = "$REAL_PREFIX" ]
  [ "$(daw_env_value HOME)" = "$PRODUCTION_HOME" ]
}

@test "launcher names pasta or slirp when MAC identity tools are missing" {
  setup_mac_identity_fixtures
  mkdir -p "$BATS_TEST_TMPDIR/empty-bin" "$BATS_TEST_TMPDIR/sys-bin"
  local saved_path="$PATH" cmd src
  rm -f "$FIXTURE_BIN/pasta" "$FIXTURE_BIN/slirp4netns"
  # Keep the tools the preflight needs, but omit pasta/passt/slirp4netns so
  # a host install cannot satisfy --mac after the fixture copies are removed.
  for cmd in realpath mkdir cat printf id basename dirname awk stat \
    mktemp uname head tr cut grep sed rm mv ls touch chmod ln readlink \
    env bash; do
    src="$(command -v "$cmd" 2>/dev/null)" || continue
    ln -s "$src" "$BATS_TEST_TMPDIR/sys-bin/$cmd"
  done
  export PATH="$BATS_TEST_TMPDIR/empty-bin:$FIXTURE_BIN:$BATS_TEST_TMPDIR/sys-bin"

  run_daw_fixture --mac 02:00:5e:00:53:01 --nic eno1 --prefix "$REAL_PREFIX" \
    fake-daw

  export PATH="$saved_path"
  [ "$status" -ne 0 ]
  [[ "$output" == *"pasta"* || "$output" == *"passt"* ]]
  [ ! -e "$DAW_ENV_FILE" ]
  refute_launcher_mutation
}

@test "launcher --mac implies shared networking without an explicit --network" {
  setup_mac_identity_fixtures

  run_daw_fixture --mac 02:00:5e:00:53:01 --nic eno1 --prefix "$REAL_PREFIX" \
    fake-daw

  [ "$status" -eq 0 ]
  [[ "$(launched_argv)" != *" --unshare-net "* ]]
  [[ "$output" == *"mac identity"* || "$output" == *"02:00:5e:00:53:01"* ]]
}

@test "launcher unwraps xln-fj so firejail is not nested inside bwrap" {
  setup_mac_identity_fixtures
  write_fake_firejail "$FIXTURE_BIN/xln-fj"

  run_daw_fixture --prefix "$REAL_PREFIX" "$FIXTURE_BIN/xln-fj" fake-daw

  [ "$status" -eq 0 ]
  [[ "$(launched_pasta_argv)" == *" --mac-addr "* ]]
  [[ "$(launched_pasta_argv)" == *"02:00:5e:00:53:01"* ]]
  [[ "$(launched_argv)" == *" -- $FIXTURE_BIN/fake-daw"* ]]
  [[ "$(launched_argv)" != *"xln-fj"* ]]
  [[ "$(launched_argv)" != *" --unshare-net "* ]]
  [ ! -s "$FIREJAIL_CALLS" ]
}

@test "launcher ignores inherited XLN_MAC unless identity was requested" {
  setup_mac_identity_fixtures
  export XLN_MAC="02:00:5e:00:53:01"
  export XLN_NIC="eno1"

  run_daw_fixture --prefix "$REAL_PREFIX" fake-daw

  [ "$status" -eq 0 ]
  [ ! -s "$PASTA_CALLS" ]
  [ ! -s "$UNSHARE_CALLS" ]
  [[ "$(launched_argv)" == *" --unshare-net "* ]]
}

@test "launcher refuses a malformed --mac before cloning" {
  setup_mac_identity_fixtures

  run_daw_fixture --mac not-a-mac --nic eno1 --prefix "$REAL_PREFIX" fake-daw

  [ "$status" -eq 2 ]
  [[ "$output" == *"--mac"* ]]
  refute_launcher_mutation
}

@test "launcher --address requires --mac and pins pasta guest IPv4" {
  setup_mac_identity_fixtures

  run_daw_fixture --address 192.0.2.132 --prefix "$REAL_PREFIX" fake-daw

  [ "$status" -eq 2 ]
  [[ "$output" == *"--address"* ]]
  [[ "$output" == *"--mac"* ]]
  refute_launcher_mutation

  run_daw_fixture --mac 02:00:5e:00:53:01 --nic eno1 --address 192.0.2.132 \
    --prefix "$REAL_PREFIX" fake-daw

  [ "$status" -eq 0 ]
  [[ "$(launched_pasta_argv)" == argv0\ pasta\ * ]]
  [[ "$(launched_pasta_argv)" == *" --address "* ]]
  [[ "$(launched_pasta_argv)" == *"192.0.2.132"* ]]
  [[ "$(launched_pasta_argv)" == *" --ns-ifname "* ]]
  [[ "$(launched_pasta_argv)" == *" eth0 "* ]]
  [ "$(daw_env_value WINEPREFIX)" = "$REAL_PREFIX" ]
}

@test "launcher refuses a malformed --address before cloning" {
  setup_mac_identity_fixtures

  run_daw_fixture --mac 02:00:5e:00:53:01 --nic eno1 --address not-an-ip \
    --prefix "$REAL_PREFIX" fake-daw

  [ "$status" -eq 2 ]
  [[ "$output" == *"--address"* ]]
  refute_launcher_mutation
}

@test "launcher refuses a nested firejail DAW instead of launching it inside bwrap" {
  setup_mac_identity_fixtures
  write_fake_firejail "$FIXTURE_BIN/firejail"

  run_daw_fixture --network --prefix "$REAL_PREFIX" "$FIXTURE_BIN/firejail" \
    fake-daw

  [ "$status" -ne 0 ]
  [[ "$output" == *"firejail"* ]]
  refute_launcher_mutation
}

@test "MAC identity keeps prefix overlay and gives the DAW the host HOME" {
  setup_mac_identity_fixtures
  mkdir -p "$PRODUCTION_HOME/.BitwigStudio" "$PRODUCTION_HOME/Documents"
  printf '%s\n' 'license' > "$PRODUCTION_HOME/.BitwigStudio/.eula-agreed"

  run_daw_fixture --mac 02:00:5e:00:53:01 --nic eno1 --prefix "$REAL_PREFIX" \
    fake-daw

  [ "$status" -eq 0 ]
  [[ "$(launched_argv)" == *" --bind $COPY $REAL_PREFIX "* ]]
  [[ "$(launched_argv)" == *" --bind $PRODUCTION_HOME $PRODUCTION_HOME "* ]]
  [[ "$(launched_argv)" == *" --setenv HOME $PRODUCTION_HOME "* ]]
  [[ "$(launched_argv)" == *" --uid $(id -u) "* ]]
  [[ "$(launched_argv)" == *" --gid $(id -g) "* ]]
  [[ "$(launched_argv)" != *" --setenv HOME $ISOLATED_HOME "* ]]
  [[ "$(launched_argv)" != *" --bind $PRODUCTION_HOME/.BitwigStudio $ISOLATED_HOME/.BitwigStudio "* ]]
}

@test "launcher binds explicit writable paths and nothing else" {
  run_daw_fixture --prefix "$REAL_PREFIX" --writable-path "$PROJECTS" fake-daw

  [ "$status" -eq 0 ]
  [[ "$(launched_argv)" == *" --bind $PROJECTS $PROJECTS "* ]]
}

@test "launcher binds the host home so Bitwig settings are at \$HOME/.BitwigStudio" {
  mkdir -p "$PRODUCTION_HOME/.BitwigStudio"
  printf '%s\n' 'license' > "$PRODUCTION_HOME/.BitwigStudio/.eula-agreed"

  run_daw_fixture --prefix "$REAL_PREFIX" fake-daw

  [ "$status" -eq 0 ]
  [[ "$(launched_argv)" == *" --bind $PRODUCTION_HOME $PRODUCTION_HOME "* ]]
  [[ "$(launched_argv)" == *" --setenv HOME $PRODUCTION_HOME "* ]]
  [[ "$(launched_argv)" != *" --bind $PRODUCTION_HOME/.BitwigStudio $ISOLATED_HOME/.BitwigStudio "* ]]
}

@test "launcher exposes Wine known folders through the host home bind" {
  mkdir -p "$PRODUCTION_HOME/Documents/Addictive Drums 2"

  run_daw_fixture --prefix "$REAL_PREFIX" fake-daw

  [ "$status" -eq 0 ]
  [[ "$(launched_argv)" == *" --bind $PRODUCTION_HOME $PRODUCTION_HOME "* ]]
  [[ "$(launched_argv)" != *" --bind $PRODUCTION_HOME/Documents $ISOLATED_HOME/Documents "* ]]
}

@test "launcher does not remap an explicit home-relative writable path into isolated HOME" {
  local projects="$PRODUCTION_HOME/Bitwig Studio"
  mkdir -p "$projects"
  local quoted isolated_quoted
  quoted="$(printf '%q' "$projects")"
  isolated_quoted="$(printf '%q' "$ISOLATED_HOME/Bitwig Studio")"

  run_daw_fixture --prefix "$REAL_PREFIX" --writable-path "$projects" fake-daw

  [ "$status" -eq 0 ]
  [[ "$(launched_argv)" == *" --bind $PRODUCTION_HOME $PRODUCTION_HOME "* ]]
  [[ "$(launched_argv)" == *" --setenv HOME $PRODUCTION_HOME "* ]]
  [[ "$(launched_argv)" != *" --bind $quoted $isolated_quoted "* ]]
}

@test "launcher accepts an explicit Bitwig config path that auto-bind would also add" {
  mkdir -p "$PRODUCTION_HOME/.BitwigStudio"

  run_daw_fixture --prefix "$REAL_PREFIX" \
    --writable-path "$PRODUCTION_HOME/.BitwigStudio" fake-daw

  [ "$status" -eq 0 ]
  [[ "$(launched_argv)" == *" --setenv HOME $PRODUCTION_HOME "* ]]
  [[ "$(launched_argv)" != *" --bind $PRODUCTION_HOME/.BitwigStudio $ISOLATED_HOME/.BitwigStudio "* ]]
}

@test "launcher does not invent a missing Bitwig config directory" {
  run_daw_fixture --prefix "$REAL_PREFIX" fake-daw

  [ "$status" -eq 0 ]
  [ ! -e "$PRODUCTION_HOME/.BitwigStudio" ]
  [[ "$(launched_argv)" != *".BitwigStudio"* ]]
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
    "$PRODUCTION_HOME/.vst3/yabridge:/usr/lib/vst3" ]
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
  if ! "$real_bwrap" --unshare-user --unshare-pid --unshare-uts \
    --unshare-cgroup-try --unshare-net --die-with-parent --new-session \
    --ro-bind /usr /usr --proc /proc --dev /dev --bind /dev/shm /dev/shm \
    --tmpfs /tmp \
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
    printf 'prefix-path-write=succeeded\n'
  else
    printf 'prefix-path-write=failed\n'
  fi
  if printf 'injected' \
    > "$PRODUCTION_HOME/.vst/yabridge/Injected.so" 2>/dev/null; then
    printf 'yabridge-path-write=succeeded\n'
  else
    printf 'yabridge-path-write=failed\n'
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
  printf 'prefix-path-visible=%s\n' "\$(cat "$REAL_PREFIX/drive_c/production.txt")"
} > "$report"
EOF
  chmod +x "$FIXTURE_BIN/mutating-daw"
  local before
  before="$(sha256sum < "$REAL_PREFIX/drive_c/production.txt")"

  run "$FIXTURE_ROOT/daw-env.sh" --prefix "$REAL_PREFIX" \
    --writable-path "$PROJECTS" mutating-daw

  [ "$status" -eq 0 ]
  [ -f "$report" ]
  grep -Fxq 'prefix-path-write=succeeded' "$report"
  grep -Fxq 'yabridge-path-write=succeeded' "$report"
  grep -Fxq 'clone-write=succeeded' "$report"
  grep -Fxq 'approved-write=succeeded' "$report"
  grep -Fxq 'prefix-path-visible=changed' "$report"
  [ "$(sha256sum < "$REAL_PREFIX/drive_c/production.txt")" = "$before" ]
  [ ! -e "$PRODUCTION_HOME/.vst/yabridge/Injected.so" ]
  [ "$(cat "$ISOLATED_HOME/.vst/yabridge/Injected.so")" = "injected" ]
  [ "$(cat "$COPY/drive_c/production.txt")" = "changed" ]
  [ "$(cat "$COPY/drive_c/clone.txt")" = "changed" ]
  [ "$(cat "$PROJECTS/output.wav")" = "rendered" ]
}

@test "a sandboxed DAW sees Wine known folders through the host HOME" {
  require_live_sandbox
  local documents="$PRODUCTION_HOME/Documents"
  local wine_user="$REAL_PREFIX/drive_c/users/wineuser"
  mkdir -p "$documents/Addictive Drums 2" "$wine_user"
  printf '%s\n' 'xln-settings' > "$documents/Addictive Drums 2/settings"
  ln -s "$documents" "$wine_user/Documents"
  local report="$PROJECTS/report"
  cat > "$FIXTURE_BIN/wine-folders-daw" <<EOF
#!/bin/bash
{
  printf 'home=%s\n' "\$HOME"
  if [[ -d "\$HOME/Documents" ]]; then
    printf 'isolated-documents=present\n'
  else
    printf 'isolated-documents=missing\n'
  fi
  if [[ -f "\$HOME/Documents/Addictive Drums 2/settings" ]]; then
    printf 'isolated-xln=%s\n' "\$(cat "\$HOME/Documents/Addictive Drums 2/settings")"
  else
    printf 'isolated-xln=missing\n'
  fi
  if [[ -f "$documents/Addictive Drums 2/settings" ]]; then
    printf 'host-documents=%s\n' "\$(cat "$documents/Addictive Drums 2/settings")"
  else
    printf 'host-documents=missing\n'
  fi
  if [[ -f "$REAL_PREFIX/drive_c/users/wineuser/Documents/Addictive Drums 2/settings" ]]; then
    printf 'wine-user-documents=%s\n' \
      "\$(cat "$REAL_PREFIX/drive_c/users/wineuser/Documents/Addictive Drums 2/settings")"
  else
    printf 'wine-user-documents=missing\n'
  fi
  if printf 'from-isolated-documents' \
    > "\$HOME/Documents/Addictive Drums 2/written" 2>/dev/null; then
    printf 'documents-write=succeeded\n'
  else
    printf 'documents-write=failed\n'
  fi
  if printf 'changed' > "$REAL_PREFIX/drive_c/production.txt" 2>/dev/null; then
    printf 'prefix-path-write=succeeded\n'
  else
    printf 'prefix-path-write=failed\n'
  fi
} > "$report"
EOF
  chmod +x "$FIXTURE_BIN/wine-folders-daw"
  local before
  before="$(sha256sum < "$REAL_PREFIX/drive_c/production.txt")"

  run "$FIXTURE_ROOT/daw-env.sh" --prefix "$REAL_PREFIX" \
    --writable-path "$PROJECTS" wine-folders-daw

  [ "$status" -eq 0 ]
  [ -f "$report" ]
  grep -Fxq "home=$PRODUCTION_HOME" "$report"
  grep -Fxq 'isolated-documents=present' "$report"
  grep -Fxq 'isolated-xln=xln-settings' "$report"
  grep -Fxq 'host-documents=xln-settings' "$report"
  grep -Fxq 'wine-user-documents=xln-settings' "$report"
  grep -Fxq 'documents-write=succeeded' "$report"
  grep -Fxq 'prefix-path-write=succeeded' "$report"
  [ "$(cat "$documents/Addictive Drums 2/written")" = "from-isolated-documents" ]
  [ "$(sha256sum < "$REAL_PREFIX/drive_c/production.txt")" = "$before" ]
}

write_bitwig_state_daw() {
  local report="$1"
  cat > "$FIXTURE_BIN/bitwig-state-daw" <<EOF
#!/bin/bash
{
  printf 'home=%s\n' "\$HOME"
  if [[ -f "\$HOME/.BitwigStudio/.eula-agreed" ]]; then
    printf 'license=%s\n' "\$(cat "\$HOME/.BitwigStudio/.eula-agreed")"
  else
    printf 'license=missing\n'
  fi
  printf 'uid=%s\n' "\$(id -u)"
  printf 'passwd-home=%s\n' "\$(getent passwd "\$(id -u)" | cut -d: -f6)"
  if printf 'from-host-home' > "\$HOME/.BitwigStudio/written" 2>/dev/null; then
    printf 'config-write=succeeded\n'
  else
    printf 'config-write=failed\n'
  fi
  if printf 'changed' > "$REAL_PREFIX/drive_c/production.txt" 2>/dev/null; then
    printf 'prefix-path-write=succeeded\n'
  else
    printf 'prefix-path-write=failed\n'
  fi
} > "$report"
EOF
  chmod +x "$FIXTURE_BIN/bitwig-state-daw"
}

@test "a sandboxed DAW sees and writes the real Bitwig config at host HOME" {
  require_live_sandbox
  mkdir -p "$PRODUCTION_HOME/.BitwigStudio"
  printf '%s\n' 'license' > "$PRODUCTION_HOME/.BitwigStudio/.eula-agreed"
  local report="$PROJECTS/report"
  write_bitwig_state_daw "$report"
  local before
  before="$(sha256sum < "$REAL_PREFIX/drive_c/production.txt")"

  run "$FIXTURE_ROOT/daw-env.sh" --prefix "$REAL_PREFIX" \
    --writable-path "$PROJECTS" bitwig-state-daw

  [ "$status" -eq 0 ]
  [ -f "$report" ]
  grep -Fxq "home=$PRODUCTION_HOME" "$report"
  grep -Fxq "passwd-home=$PRODUCTION_HOME" "$report"
  grep -Fxq "uid=$(id -u)" "$report"
  grep -Fxq 'license=license' "$report"
  grep -Fxq 'config-write=succeeded' "$report"
  grep -Fxq 'prefix-path-write=succeeded' "$report"
  [ "$(cat "$PRODUCTION_HOME/.BitwigStudio/written")" = "from-host-home" ]
  [ "$(sha256sum < "$REAL_PREFIX/drive_c/production.txt")" = "$before" ]
}

# HOME + --mac + pasta: construction tests passed while live Bitwig still
# opened /root/.BitwigStudio (map-root-user + Java getpwuid) or leftover
# isolation/home/.BitwigStudio. This launch path must keep host HOME.
@test "a sandboxed DAW with MAC identity uses host HOME not isolated leftover" {
  require_live_sandbox
  local real_pasta real_unshare
  real_pasta="$(command -v pasta 2>/dev/null || true)"
  real_unshare="$(command -v unshare 2>/dev/null || true)"
  [[ -n "$real_pasta" && -x "$real_pasta" ]] ||
    skip "pasta is not installed (Arch: pacman -S passt)"
  [[ -n "$real_unshare" && -x "$real_unshare" ]] || skip "unshare is not installed"
  rm -f "$FIXTURE_BIN/bwrap" "$FIXTURE_BIN/unshare" "$FIXTURE_BIN/pasta"

  mkdir -p "$PRODUCTION_HOME/.BitwigStudio"
  printf '%s\n' 'license' > "$PRODUCTION_HOME/.BitwigStudio/.eula-agreed"
  local report="$PROJECTS/report"
  write_bitwig_state_daw "$report"
  local before
  before="$(sha256sum < "$REAL_PREFIX/drive_c/production.txt")"

  run "$FIXTURE_ROOT/daw-env.sh" --mac 02:00:5e:00:53:01 --nic eno1 \
    --prefix "$REAL_PREFIX" --writable-path "$PROJECTS" bitwig-state-daw

  [ "$status" -eq 0 ]
  [ -f "$report" ]
  grep -Fxq "home=$PRODUCTION_HOME" "$report"
  grep -Fxq "passwd-home=$PRODUCTION_HOME" "$report"
  grep -Fxq "uid=$(id -u)" "$report"
  refute grep -Fxq "home=$ISOLATED_HOME" "$report"
  refute grep -Fxq 'home=/root' "$report"
  grep -Fxq 'license=license' "$report"
  grep -Fxq 'config-write=succeeded' "$report"
  [ "$(cat "$PRODUCTION_HOME/.BitwigStudio/written")" = "from-host-home" ]
  [ "$(sha256sum < "$REAL_PREFIX/drive_c/production.txt")" = "$before" ]
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
  grep -Fxq 'alias-create=succeeded' "$report"
  grep -Fxq 'alias-overwrite=succeeded' "$report"
  [ ! -e "$target/yabridge/Injected.so" ]
  [ "$(cat "$target/yabridge/Production.so")" = "production bridge" ]
  [ "$(cat "$ISOLATED_HOME/.vst/yabridge/Injected.so")" = "injected" ]
}

@test "live bwrap overlays isolated yabridge when ~/.vst is a symlink" {
  require_live_sandbox
  local vst_target="$BATS_TEST_TMPDIR/audio-production/.vst"
  local vst3_target="$BATS_TEST_TMPDIR/audio-production/.vst3"
  local clap_target="$BATS_TEST_TMPDIR/audio-production/.clap"
  alias_plugin_root .vst "$vst_target"
  alias_plugin_root .vst3 "$vst3_target"
  alias_plugin_root .clap "$clap_target"
  ln -s "$REAL_PREFIX" "$PRODUCTION_HOME/winplugins"

  local report="$PROJECTS/report"
  cat > "$FIXTURE_BIN/symlink-root-daw" <<EOF
#!/bin/bash
{
  printf 'home=%s\n' "\$HOME"
  if printf 'injected' > "\$HOME/.vst/yabridge/Injected.so" 2>/dev/null; then
    printf 'lexical-write=succeeded\n'
  else
    printf 'lexical-write=failed\n'
  fi
  if printf 'injected3' > "\$HOME/.vst3/yabridge/Injected.so" 2>/dev/null; then
    printf 'vst3-write=succeeded\n'
  else
    printf 'vst3-write=failed\n'
  fi
  if printf 'changed' > "$vst_target/yabridge/Production.so" 2>/dev/null; then
    printf 'canonical-overwrite=succeeded\n'
  else
    printf 'canonical-overwrite=failed\n'
  fi
  printf 'lexical-good=%s\n' "\$(cat "\$HOME/.vst/yabridge/Good.so")"
} > "$report"
EOF
  chmod +x "$FIXTURE_BIN/symlink-root-daw"

  run "$FIXTURE_ROOT/daw-env.sh" --prefix "$REAL_PREFIX" \
    --writable-path "$PROJECTS" symlink-root-daw

  [ "$status" -eq 0 ]
  [ -f "$report" ]
  grep -Fxq "home=$PRODUCTION_HOME" "$report"
  grep -Fxq 'lexical-write=succeeded' "$report"
  grep -Fxq 'vst3-write=succeeded' "$report"
  grep -Fxq 'canonical-overwrite=succeeded' "$report"
  grep -Fxq 'lexical-good=native' "$report"
  [ ! -e "$vst_target/yabridge/Injected.so" ]
  [ ! -e "$vst3_target/yabridge/Injected.so" ]
  [ "$(cat "$vst_target/yabridge/Production.so")" = "production bridge" ]
  [ "$(cat "$ISOLATED_HOME/.vst/yabridge/Injected.so")" = "injected" ]
  [ "$(cat "$ISOLATED_HOME/.vst3/yabridge/Injected.so")" = "injected3" ]
  [ "$(cat "$ISOLATED_HOME/.vst/yabridge/Production.so")" = "changed" ]
}

# Interfaces are read from /proc/net/dev, which procfs reports per network
# namespace. Nothing here contacts a host or a remote, so the test cannot hang
# on an unreachable network.
@test "a sandboxed DAW sees the host home and no host network interface" {
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
  grep -Fxq 'home-sibling=visible' "$report"
  grep -Fxq 'home-documents=visible' "$report"
  # The prefix is deliberately visible at its host path (clone overlay);
  # hiding the rest of the home is what this asserts.
  grep -Fxq 'prefix=visible' "$report"
  local interfaces
  interfaces="$(sed -n 's/^interfaces=//p' "$report" | tr -s ' ' | sed 's/ *$//')"
  [ "$interfaces" = "lo" ]
}

@test "owned-userns pasta MAC identity is visible inside a live sandbox" {
  require_live_sandbox
  local real_pasta real_unshare
  real_pasta="$(command -v pasta 2>/dev/null || true)"
  real_unshare="$(command -v unshare 2>/dev/null || true)"
  [[ -n "$real_pasta" && -x "$real_pasta" ]] ||
    skip "pasta is not installed (Arch: pacman -S passt)"
  [[ -n "$real_unshare" && -x "$real_unshare" ]] || skip "unshare is not installed"
  rm -f "$FIXTURE_BIN/bwrap" "$FIXTURE_BIN/unshare" "$FIXTURE_BIN/pasta"

  local report="$PROJECTS/report"
  cat > "$FIXTURE_BIN/identity-daw" <<EOF
#!/bin/bash
{
  printf 'machine-id=%s\n' "\$(cat /etc/machine-id 2>/dev/null || echo missing)"
  printf 'macs=%s\n' "\$(cat /sys/class/net/*/address 2>/dev/null | tr '\n' ' ')"
  printf 'interfaces=%s\n' \
    "\$(cut -d: -f1 /proc/net/dev | tail -n +3 | tr -d ' ' | tr '\n' ' ')"
  printf 'addrs=%s\n' "\$(ip -4 -o addr show 2>/dev/null | tr '\n' ';')"
  printf 'routes=%s\n' "\$(ip -4 route 2>/dev/null | tr '\n' ';')"
} > "$report"
EOF
  chmod +x "$FIXTURE_BIN/identity-daw"

  run "$FIXTURE_ROOT/daw-env.sh" --mac 02:00:5e:00:53:01 --nic eno1 \
    --prefix "$REAL_PREFIX" --writable-path "$PROJECTS" identity-daw

  [ "$status" -eq 0 ]
  [ -f "$report" ]
  grep -Fq '02:00:5e:00:53:01' "$report"
  local interfaces addrs routes
  interfaces="$(sed -n 's/^interfaces=//p' "$report")"
  addrs="$(sed -n 's/^addrs=//p' "$report")"
  routes="$(sed -n 's/^routes=//p' "$report")"
  # Pasta templates from --nic (eno1) but Wine must see eth0, the same
  # single-NIC name daily xln-fj / Firejail typically presents. docker0
  # must still stay out.
  [[ "$interfaces" == *eth0* ]]
  [[ "$interfaces" != *eno1* ]]
  [[ "$interfaces" != *docker0* ]]
  # Local-mode pasta NATs to 127.0.0.1 via 169.254.2.2. Host-templated
  # pasta copies the outbound interface instead.
  [[ "$addrs" != *169.254.2.* ]]
  [[ "$routes" != *169.254.2.2* ]]
}

@test "owned-userns pasta can pin the guest IPv4 Wine would see" {
  require_live_sandbox
  local real_pasta real_unshare
  real_pasta="$(command -v pasta 2>/dev/null || true)"
  real_unshare="$(command -v unshare 2>/dev/null || true)"
  [[ -n "$real_pasta" && -x "$real_pasta" ]] ||
    skip "pasta is not installed (Arch: pacman -S passt)"
  [[ -n "$real_unshare" && -x "$real_unshare" ]] || skip "unshare is not installed"
  rm -f "$FIXTURE_BIN/bwrap" "$FIXTURE_BIN/unshare" "$FIXTURE_BIN/pasta"

  local report="$PROJECTS/report"
  cat > "$FIXTURE_BIN/address-daw" <<EOF
#!/bin/bash
{
  printf 'interfaces=%s\n' \
    "\$(cut -d: -f1 /proc/net/dev | tail -n +3 | tr -d ' ' | tr '\n' ' ')"
  printf 'macs=%s\n' "\$(cat /sys/class/net/*/address 2>/dev/null | tr '\n' ' ')"
  printf 'addrs=%s\n' "\$(ip -4 -o addr show 2>/dev/null | tr '\n' ';')"
} > "$report"
EOF
  chmod +x "$FIXTURE_BIN/address-daw"

  run "$FIXTURE_ROOT/daw-env.sh" --mac 02:00:5e:00:53:01 --nic eno1 \
    --address 192.0.2.132 \
    --prefix "$REAL_PREFIX" --writable-path "$PROJECTS" address-daw

  [ "$status" -eq 0 ]
  [ -f "$report" ]
  grep -Fq '02:00:5e:00:53:01' "$report"
  local interfaces addrs
  interfaces="$(sed -n 's/^interfaces=//p' "$report")"
  addrs="$(sed -n 's/^addrs=//p' "$report")"
  [[ "$interfaces" == *eth0* ]]
  [[ "$interfaces" != *eno1* ]]
  [[ "$addrs" == *192.0.2.132* ]]
  [[ "$addrs" != *169.254.2.* ]]
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
