#!/usr/bin/env bats

load test_helper

setup() {
  FIXTURE_ROOT="$BATS_TEST_TMPDIR/project"
  FIXTURE_BIN="$BATS_TEST_TMPDIR/bin"
  SOURCE="$BATS_TEST_TMPDIR/source"
  CALLS="$BATS_TEST_TMPDIR/cp.calls"
  DAW_PREFIX="$BATS_TEST_TMPDIR/daw-prefix"

  YABRIDGE_HOME="$FIXTURE_ROOT/build/yabridge"

  PRODUCTION_HOME="$BATS_TEST_TMPDIR/production-home"

  mkdir -p "$FIXTURE_ROOT/lib" "$FIXTURE_BIN" "$YABRIDGE_HOME" \
    "$PRODUCTION_HOME"
  cp "$PROJECT_ROOT/daw-env.sh" "$FIXTURE_ROOT/daw-env.sh"
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

  cat > "$YABRIDGE_HOME/yabridgectl" <<'EOF'
#!/bin/bash
set -euo pipefail
if [[ "${1:-}" == sync ]]; then
  mkdir -p "$HOME/.vst/yabridge"
  printf '%s\n' 'native' > "$HOME/.vst/yabridge/Good.so"
  ln -s "$DAW_TEST_CLONE/Good.dll" "$HOME/.vst/yabridge/Good.dll"
fi
EOF
  chmod +x "$YABRIDGE_HOME/yabridgectl"
  export DAW_TEST_CLONE="$FIXTURE_ROOT/prefix-copy"

  cat > "$FIXTURE_BIN/fake-daw" <<EOF
#!/bin/bash
printf '%s\n' "\$WINEPREFIX" > "$DAW_PREFIX"
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
{
  printf 'argv'
  printf ' %q' "$@"
  printf '\n'
} >> "$DAW_TEST_CP_CALLS"
/bin/cp -a "$source_path" "$destination"
if [[ "${DAW_TEST_REPLACE_SOURCE_AFTER_COPY:-false}" == true ]]; then
  rm -rf "$source_path"
  mkdir -p "$source_path"
  printf '%s\n' 'WINE REGISTRY Version 2' > "$source_path/system.reg"
fi
if [[ -n "${DAW_TEST_CP_STARTED:-}" ]] &&
   (set -o noclobber; : > "$DAW_TEST_CP_STARTED") 2>/dev/null; then
  while [[ ! -e "${DAW_TEST_CP_RELEASE:?}" ]]; do
    sleep 0.02
  done
fi
if [[ "${DAW_TEST_CP_FAIL:-false}" == true ]]; then
  exit 1
fi
EOF
  chmod +x "$FIXTURE_ROOT/daw-env.sh" "$FIXTURE_BIN/fake-daw" \
    "$FIXTURE_BIN/wine" "$FIXTURE_BIN/wineserver" "$FIXTURE_BIN/cp"

  # Clone provenance is what this suite covers, so the sandbox is stubbed: the
  # fake bwrap records its argv and runs the command it was given. Real
  # Bubblewrap enforcement is covered by tests/sandbox.bats.
  write_fake_bwrap "$FIXTURE_BIN/bwrap"

  export DAW_TEST_CP_CALLS="$CALLS"
  export PATH="$FIXTURE_BIN:$PATH"
  export SANDBOX_TEST_BWRAP_CALLS="$BATS_TEST_TMPDIR/bwrap.calls"
  export HOME="$PRODUCTION_HOME"
  make_prefix "$SOURCE"
}

make_prefix() {
  local path="$1"
  mkdir -p "$path"
  printf '%s\n' 'WINE REGISTRY Version 2' > "$path/system.reg"
  printf '%s\n' 'source data' > "$path/source-sentinel"
  printf '%s\n' 'plugin' > "$path/Good.dll"
}

run_daw_fixture() {
  run "$FIXTURE_ROOT/daw-env.sh" "$@"
}

source_identity() {
  stat -Lc '%d %i' "$1"
}

write_provenance() {
  local clone="$1"
  local source="$2"
  local device inode
  read -r device inode <<< "$(source_identity "$source")"
  printf '%s\n%s\n%s\n' "$(realpath "$source")" "$device" "$inode" \
    > "$clone/.yabridge-staging-source"
}

@test "launcher records canonical source provenance after a successful clone" {
  local canonical device inode
  canonical="$(realpath "$SOURCE")"
  read -r device inode <<< "$(source_identity "$SOURCE")"

  run_daw_fixture --prefix "$SOURCE" fake-daw

  [ "$status" -eq 0 ]
  [ "$(cat "$DAW_PREFIX")" = "$FIXTURE_ROOT/prefix-copy" ]
  mapfile -t provenance < "$FIXTURE_ROOT/prefix-copy/.yabridge-staging-source"
  [ "${provenance[0]}" = "$canonical" ]
  [ "${provenance[1]}" = "$device" ]
  [ "${provenance[2]}" = "$inode" ]
}

@test "launcher reuses only a clone with matching source provenance" {
  run_daw_fixture --prefix "$SOURCE" fake-daw
  [ "$status" -eq 0 ]

  run_daw_fixture --prefix "$SOURCE" fake-daw

  [ "$status" -eq 0 ]
  [ "$(wc -l < "$CALLS")" -eq 1 ]
}

@test "launcher refuses a clone created from another source prefix" {
  local source_b="$BATS_TEST_TMPDIR/source-b"
  make_prefix "$source_b"
  run_daw_fixture --prefix "$SOURCE" fake-daw
  [ "$status" -eq 0 ]

  run_daw_fixture --prefix "$source_b" fake-daw

  [ "$status" -ne 0 ]
  [[ "$output" == *"clone belongs to a different source prefix"* ]]
  [ -f "$FIXTURE_ROOT/prefix-copy/source-sentinel" ]
}

@test "launcher refuses reuse after the source inode changes" {
  run_daw_fixture --prefix "$SOURCE" fake-daw
  [ "$status" -eq 0 ]
  rm -rf "$SOURCE"
  make_prefix "$SOURCE"

  run_daw_fixture --prefix "$SOURCE" fake-daw

  [ "$status" -ne 0 ]
  [[ "$output" == *"clone belongs to a different source prefix"* ]]
}

@test "launcher refuses a partial clone without provenance" {
  mkdir -p "$FIXTURE_ROOT/prefix-copy"
  printf '%s\n' 'keep partial' > "$FIXTURE_ROOT/prefix-copy/partial"

  run_daw_fixture --prefix "$SOURCE" fake-daw

  [ "$status" -ne 0 ]
  [[ "$output" == *"clone is incomplete"* ]]
  [ "$(cat "$FIXTURE_ROOT/prefix-copy/partial")" = "keep partial" ]
  [ ! -e "$DAW_PREFIX" ]
}

@test "launcher refuses provenance-only clone state without a Wine prefix" {
  mkdir -p "$FIXTURE_ROOT/prefix-copy"
  write_provenance "$FIXTURE_ROOT/prefix-copy" "$SOURCE"

  run_daw_fixture --prefix "$SOURCE" fake-daw

  [ "$status" -ne 0 ]
  [[ "$output" == *"clone is incomplete"* ]]
  [ -f "$FIXTURE_ROOT/prefix-copy/.yabridge-staging-source" ]
  [ ! -e "$DAW_PREFIX" ]
}

@test "launcher rejects a symlinked clone destination without touching its target" {
  local target="$BATS_TEST_TMPDIR/clone-target"
  mkdir -p "$target"
  printf '%s\n' 'do not touch' > "$target/sentinel"
  ln -s "$target" "$FIXTURE_ROOT/prefix-copy"

  run_daw_fixture --prefix "$SOURCE" fake-daw

  [ "$status" -ne 0 ]
  [[ "$output" == *"clone destination is a symlink"* ]]
  [ "$(cat "$target/sentinel")" = "do not touch" ]
}

@test "launcher rejects source and clone equality without deleting the source" {
  make_prefix "$FIXTURE_ROOT/prefix-copy"

  run_daw_fixture --prefix "$FIXTURE_ROOT/prefix-copy" fake-daw

  [ "$status" -ne 0 ]
  [[ "$output" == *"source and clone paths must be separate"* ]]
  [ -f "$FIXTURE_ROOT/prefix-copy/system.reg" ]
}

@test "launcher rejects a clone nested inside its source" {
  make_prefix "$FIXTURE_ROOT"

  run_daw_fixture --prefix "$FIXTURE_ROOT" fake-daw

  [ "$status" -ne 0 ]
  [[ "$output" == *"source and clone paths must not be nested"* ]]
  [ -f "$FIXTURE_ROOT/system.reg" ]
}

@test "launcher rejects a source nested inside the clone destination" {
  make_prefix "$FIXTURE_ROOT/prefix-copy/source"

  run_daw_fixture --prefix "$FIXTURE_ROOT/prefix-copy/source" fake-daw

  [ "$status" -ne 0 ]
  [[ "$output" == *"source and clone paths must not be nested"* ]]
  [ -f "$FIXTURE_ROOT/prefix-copy/source/system.reg" ]
}

@test "launcher canonicalizes a symlinked launch path before nesting checks" {
  local real_root="$SOURCE/launcher-real"
  local linked_root="$BATS_TEST_TMPDIR/launcher-link"
  mv "$FIXTURE_ROOT" "$real_root"
  ln -s "$real_root" "$linked_root"

  run "$linked_root/daw-env.sh" --prefix "$SOURCE" fake-daw

  [ "$status" -ne 0 ]
  [[ "$output" == *"source and clone paths must not be nested"* ]]
  [ ! -e "$CALLS" ]
  [ ! -e "$real_root/prefix-copy" ]
  refute compgen -G "$real_root/prefix-copy.new.*"
  [ -f "$SOURCE/system.reg" ]
}

@test "clone creation requires the reflink-always copy argument" {
  run_daw_fixture --prefix "$SOURCE" fake-daw

  [ "$status" -eq 0 ]
  local copy_argv
  copy_argv="$(cat "$CALLS")"
  [[ "$copy_argv" == *" --reflink=always "* ]]
  [[ "$copy_argv" == *" -a "* ]]
  [[ "$copy_argv" == *" $SOURCE "* ]]
  [[ "$copy_argv" == *" $FIXTURE_ROOT/prefix-copy.new."* ]]
}

@test "failed reflink copy removes only its temporary clone" {
  export DAW_TEST_CP_FAIL=true

  run_daw_fixture --prefix "$SOURCE" fake-daw

  [ "$status" -ne 0 ]
  [[ "$output" == *"reflink clone failed"* ]]
  [ -f "$SOURCE/source-sentinel" ]
  [ ! -e "$FIXTURE_ROOT/prefix-copy" ]
  shopt -s nullglob
  local candidates=("$FIXTURE_ROOT"/prefix-copy.new.*)
  [ "${#candidates[@]}" -eq 0 ]
}

@test "source replacement during copying refuses activation" {
  export DAW_TEST_REPLACE_SOURCE_AFTER_COPY=true

  run_daw_fixture --prefix "$SOURCE" fake-daw

  [ "$status" -ne 0 ]
  [[ "$output" == *"source prefix changed during cloning"* ]]
  [ ! -e "$FIXTURE_ROOT/prefix-copy" ]
  shopt -s nullglob
  local candidates=("$FIXTURE_ROOT"/prefix-copy.new.*)
  [ "${#candidates[@]}" -eq 0 ]
}

@test "failed fresh clone preserves the complete existing clone" {
  run_daw_fixture --prefix "$SOURCE" fake-daw
  [ "$status" -eq 0 ]
  printf '%s\n' 'existing clone' > "$FIXTURE_ROOT/prefix-copy/existing"
  export DAW_TEST_CP_FAIL=true

  run_daw_fixture --fresh --prefix "$SOURCE" fake-daw

  [ "$status" -ne 0 ]
  [ "$(cat "$FIXTURE_ROOT/prefix-copy/existing")" = "existing clone" ]
  [ -f "$FIXTURE_ROOT/prefix-copy/.yabridge-staging-source" ]
}

@test "successful fresh clone atomically replaces content and provenance" {
  printf '%s\n' 'old source data' > "$SOURCE/source-sentinel"
  run_daw_fixture --prefix "$SOURCE" fake-daw
  [ "$status" -eq 0 ]
  printf '%s\n' 'old clone only' > "$FIXTURE_ROOT/prefix-copy/old-only"
  printf '%s\n' 'new source data' > "$SOURCE/source-sentinel"

  run_daw_fixture --fresh --prefix "$SOURCE" fake-daw

  [ "$status" -eq 0 ]
  [ "$(cat "$FIXTURE_ROOT/prefix-copy/source-sentinel")" = "new source data" ]
  [ ! -e "$FIXTURE_ROOT/prefix-copy/old-only" ]
  mapfile -t provenance < "$FIXTURE_ROOT/prefix-copy/.yabridge-staging-source"
  local device inode
  read -r device inode <<< "$(source_identity "$SOURCE")"
  [ "${provenance[0]}" = "$(realpath "$SOURCE")" ]
  [ "${provenance[1]}" = "$device" ]
  [ "${provenance[2]}" = "$inode" ]
  refute compgen -G "$FIXTURE_ROOT/prefix-copy.new.*"
}

@test "fresh fails before copying when GNU mv lacks atomic exchange" {
  run_daw_fixture --prefix "$SOURCE" fake-daw
  [ "$status" -eq 0 ]
  printf '%s\n' 'existing clone' > "$FIXTURE_ROOT/prefix-copy/existing"
  cat > "$FIXTURE_BIN/mv" <<'EOF'
#!/bin/bash
if [[ "${1:-}" == "--help" ]]; then
  printf '%s\n' 'Usage: mv SOURCE DEST'
  exit 0
fi
for argument in "$@"; do
  [[ "$argument" == "--exchange" ]] && exit 64
done
exec /bin/mv "$@"
EOF
  chmod +x "$FIXTURE_BIN/mv"

  run_daw_fixture --fresh --prefix "$SOURCE" fake-daw

  [ "$status" -ne 0 ]
  [[ "$output" == *"GNU coreutils mv with --exchange support is required"* ]]
  [[ "$output" == *"install or update GNU coreutils"* ]]
  [ "$(wc -l < "$CALLS")" -eq 1 ]
  [ "$(cat "$FIXTURE_ROOT/prefix-copy/existing")" = "existing clone" ]
  refute compgen -G "$FIXTURE_ROOT/prefix-copy.new.*"
}

@test "refresh bridges is accepted independently without refreshing the clone" {
  run_daw_fixture --prefix "$SOURCE" fake-daw
  [ "$status" -eq 0 ]

  run_daw_fixture --refresh-bridges --prefix "$SOURCE" fake-daw

  [ "$status" -eq 0 ]
  [ "$(wc -l < "$CALLS")" -eq 1 ]
}

@test "concurrent clone creation fails closed without touching the live candidate" {
  local started="$BATS_TEST_TMPDIR/cp-started"
  local release="$BATS_TEST_TMPDIR/cp-release"
  local first_output="$BATS_TEST_TMPDIR/first-output"
  export DAW_TEST_CP_STARTED="$started"
  export DAW_TEST_CP_RELEASE="$release"

  "$FIXTURE_ROOT/daw-env.sh" --prefix "$SOURCE" fake-daw >"$first_output" 2>&1 &
  local first_pid=$!
  while [[ ! -e "$started" ]]; do
    sleep 0.02
  done

  run_daw_fixture --prefix "$SOURCE" fake-daw
  local second_status="$status"
  local second_output="$output"
  local candidate_was_live=false
  compgen -G "$FIXTURE_ROOT/prefix-copy.new.*" >/dev/null &&
    candidate_was_live=true
  : > "$release"
  wait "$first_pid"

  [ "$second_status" -ne 0 ]
  [[ "$second_output" == *"clone operation already in progress"* ]]
  [ "$candidate_was_live" = true ]
  [ -d "$FIXTURE_ROOT/prefix-copy" ]
  [ -f "$FIXTURE_ROOT/prefix-copy/.yabridge-staging-source" ]
}

@test "clean removes only a complete clone bound to the selected source" {
  run_daw_fixture --prefix "$SOURCE" fake-daw
  [ "$status" -eq 0 ]

  run_daw_fixture --prefix "$SOURCE" --clean

  [ "$status" -eq 0 ]
  [ ! -e "$FIXTURE_ROOT/prefix-copy" ]
  [ -f "$SOURCE/system.reg" ]
}

@test "clean refuses a clone bound to another selected source" {
  local source_b="$BATS_TEST_TMPDIR/source-b"
  make_prefix "$source_b"
  run_daw_fixture --prefix "$SOURCE" fake-daw
  [ "$status" -eq 0 ]

  run_daw_fixture --prefix "$source_b" --clean

  [ "$status" -ne 0 ]
  [[ "$output" == *"clone belongs to a different source prefix"* ]]
  [ -d "$FIXTURE_ROOT/prefix-copy" ]
  [ -f "$SOURCE/system.reg" ]
  [ -f "$source_b/system.reg" ]
}

@test "fresh mismatch refusal names safe manual recovery steps" {
  local source_b="$BATS_TEST_TMPDIR/source-b"
  make_prefix "$source_b"
  run_daw_fixture --prefix "$SOURCE" fake-daw
  [ "$status" -eq 0 ]

  run_daw_fixture --fresh --prefix "$source_b" fake-daw

  [ "$status" -ne 0 ]
  [[ "$output" == *"clone belongs to a different source prefix"* ]]
  [[ "$output" == *"$FIXTURE_ROOT/prefix-copy"* ]]
  [[ "$output" == *"left untouched"* ]]
  [[ "$output" == *"cat --"*".yabridge-staging-source"* ]]
  [[ "$output" == *"stat -Lc"*"$source_b"* ]]
  [[ "$output" == *"only after verifying"* ]]
  [[ "$output" == *"rm -rf --"*"$FIXTURE_ROOT/prefix-copy"* ]]
  [ -f "$FIXTURE_ROOT/prefix-copy/source-sentinel" ]
  [ -f "$SOURCE/system.reg" ]
  [ -f "$source_b/system.reg" ]
}
