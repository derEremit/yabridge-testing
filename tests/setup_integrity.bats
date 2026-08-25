#!/usr/bin/env bats

load test_helper
load setup_fixture

WINE_SHA="6c6f642b0954248493ebbd86ec232c46a6b9cf97c747ab3f1bcb707a22efed1d"

setup() {
  setup_project_fixture
  LOCK_HOLDER_PID=""
  LOCK_RELEASE="$BATS_TEST_TMPDIR/release-setup-lock"
  LOCK_READY="$BATS_TEST_TMPDIR/setup-lock-ready"
}

teardown() {
  if [[ -n "$LOCK_HOLDER_PID" ]]; then
    touch "$LOCK_RELEASE"
    wait "$LOCK_HOLDER_PID"
  fi
}

start_setup_lock_holder() {
  (
    exec 8< "$FIXTURE_ROOT/build"
    flock -n 8
    touch "$LOCK_READY"
    while [[ ! -e "$LOCK_RELEASE" ]]; do
      sleep 0.05
    done
  ) &
  LOCK_HOLDER_PID=$!
  for _ in {1..100}; do
    [[ -e "$LOCK_READY" ]] && return 0
    sleep 0.05
  done
  return 1
}

assert_no_candidate_directories() {
  ! compgen -G "$FIXTURE_ROOT/build/.wine-candidate.*" >/dev/null
}

# Emits shell code that renames the build directory away and recreates an empty
# replacement at the same path exactly once.
swap_build_directory_snippet() {
  cat <<EOF
if [[ ! -e "$BATS_TEST_TMPDIR/build-swapped" ]]; then
  : > "$BATS_TEST_TMPDIR/build-swapped"
  /usr/bin/mv -T -- "$FIXTURE_ROOT/build" "$FIXTURE_ROOT/build.detached"
  /usr/bin/mkdir -- "$FIXTURE_ROOT/build"
fi
EOF
}

@test "setup rejects a Wine archive with the wrong digest before extraction" {
  FAKE_CHECKSUM_VALID=false

  run_setup_fixture --wine-version 11.8 --wine-sha256 \
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    --no-yabridge

  [ "$status" -ne 0 ]
  [[ "$output" == *"Wine archive checksum mismatch"* ]]
  ! grep -q '^tar ' "$CALLS"
  [ ! -e "$FIXTURE_ROOT/build/wine/bin/wine" ]
}

@test "setup rejects absolute archive entries before extraction" {
  FAKE_ARCHIVE_ENTRIES="/tmp/archive-escape"

  run_setup_fixture --wine-version 11.8 --wine-sha256 "$WINE_SHA" --no-yabridge

  [ "$status" -ne 0 ]
  [[ "$output" == *"unsafe path"* ]]
  [ "$(grep -c '^tar ' "$CALLS")" -eq 1 ]
  [ ! -e "$FIXTURE_ROOT/build/wine/bin/wine" ]
}

@test "setup rejects parent-traversing entries without replacing working Wine" {
  seed_working_wine
  FAKE_ARCHIVE_ENTRIES="wine-11.8-staging-amd64/../../archive-escape"

  run_setup_fixture --wine-version 11.8 --wine-sha256 "$WINE_SHA" --no-yabridge

  [ "$status" -ne 0 ]
  [[ "$output" == *"unsafe path"* ]]
  [ -f "$FIXTURE_ROOT/build/wine/prior-install" ]
  grep -q '^WINE_SHA256=aaaaaaaa' "$FIXTURE_ROOT/build/component-state.env"
}

@test "interrupted activation leaves the working Wine install active" {
  seed_working_wine
  FAKE_CRASH_DURING_ACTIVATION=true

  run_setup_fixture --wine-version 11.8 --wine-sha256 "$WINE_SHA" --no-yabridge

  [ "$status" -ne 0 ]
  [ -x "$FIXTURE_ROOT/build/wine/bin/wine" ]
  [ -f "$FIXTURE_ROOT/build/wine/prior-install" ]
}

@test "setup rejects an absolute symlink target before extraction" {
  seed_malicious_archive symlink "/tmp/archive-escape"

  run_setup_fixture --wine-version 11.8 --wine-sha256 "$WINE_SHA" --no-yabridge

  [ "$status" -ne 0 ]
  [[ "$output" == *"unsafe link target"* ]]
  ! grep -q 'tar -xaf' "$CALLS"
  [ ! -e "$FIXTURE_ROOT/build/wine" ]
}

@test "setup rejects a parent-traversing hard-link target before extraction" {
  seed_malicious_archive hardlink "../../archive-escape"

  run_setup_fixture --wine-version 11.8 --wine-sha256 "$WINE_SHA" --no-yabridge

  [ "$status" -ne 0 ]
  [[ "$output" == *"unsafe link target"* ]]
  ! grep -q 'tar -xaf' "$CALLS"
  [ ! -e "$FIXTURE_ROOT/build/wine" ]
}

@test "setup rejects a symlinked Wine executable after extraction" {
  seed_malicious_archive safe-symlink "real-wine"

  run_setup_fixture --wine-version 11.8 --wine-sha256 "$WINE_SHA" --no-yabridge

  [ "$status" -ne 0 ]
  [[ "$output" == *"failed validation"* ]]
  [ ! -e "$FIXTURE_ROOT/build/wine" ]
}

@test "TERM before exchange cleans the candidate and preserves active Wine" {
  seed_working_wine
  FAKE_INTERRUPT_PHASE=before-exchange

  run_setup_fixture --wine-version 11.8 --wine-sha256 "$WINE_SHA" --no-yabridge

  [ "$status" -ne 0 ]
  [ -f "$FIXTURE_ROOT/build/wine/prior-install" ]
  assert_no_candidate_directories
}

@test "TERM after exchange cleans the old install from the candidate tree" {
  seed_working_wine
  FAKE_INTERRUPT_PHASE=after-exchange

  run_setup_fixture --wine-version 11.8 --wine-sha256 "$WINE_SHA" --no-yabridge

  [ "$status" -ne 0 ]
  [ -x "$FIXTURE_ROOT/build/wine/bin/wine" ]
  [ ! -e "$FIXTURE_ROOT/build/wine/prior-install" ]
  assert_no_candidate_directories
}

@test "startup removes only recognized stale candidates" {
  seed_working_wine
  seed_stale_candidate
  mkdir -p "$FIXTURE_ROOT/build/.wine-candidate.unrecognized"
  touch "$FIXTURE_ROOT/build/.wine-candidate.unrecognized/keep"

  run_setup_fixture --no-wine --no-yabridge

  [ "$status" -eq 0 ]
  [ ! -e "$FIXTURE_ROOT/build/.wine-candidate.stale" ]
  [ -e "$FIXTURE_ROOT/build/.wine-candidate.unrecognized/keep" ]
  [ -f "$FIXTURE_ROOT/build/wine/prior-install" ]
}

@test "concurrent setup fails without deleting a live recognized candidate" {
  seed_stale_candidate ".wine-candidate.live"
  printf 'live-owner-data\n' \
    > "$FIXTURE_ROOT/build/.wine-candidate.live/live-content"
  start_setup_lock_holder

  run_setup_fixture --no-wine --no-yabridge

  [ "$status" -ne 0 ]
  [[ "$output" == *"Another setup is already running"* ]]
  [ -f "$FIXTURE_ROOT/build/.wine-candidate.live/.yabridge-candidate" ]
  grep -q '^live-owner-data$' \
    "$FIXTURE_ROOT/build/.wine-candidate.live/live-content"
  [ ! -s "$CALLS" ]
}

@test "setup fails closed when flock is unavailable" {
  seed_stale_candidate
  cat > "$FAKE_BIN/flock" <<'EOF'
#!/bin/bash
exit 127
EOF
  chmod +x "$FAKE_BIN/flock"

  run_setup_fixture --no-wine --no-yabridge

  [ "$status" -ne 0 ]
  [[ "$output" == *"flock is required"* ]]
  [ -e "$FIXTURE_ROOT/build/.wine-candidate.stale/stale-content" ]
  [ ! -s "$CALLS" ]
}

@test "setup ignores a lock-path symlink without modifying its target" {
  sentinel="$BATS_TEST_TMPDIR/lock-sentinel"
  printf 'sentinel-content\n' > "$sentinel"
  ln -s "$sentinel" "$FIXTURE_ROOT/build/.setup.lock"

  run_setup_fixture --no-wine --no-yabridge

  [ "$status" -eq 0 ]
  grep -q '^sentinel-content$' "$sentinel"
  [ -L "$FIXTURE_ROOT/build/.setup.lock" ]
  [ "$(readlink "$FIXTURE_ROOT/build/.setup.lock")" = "$sentinel" ]
}

@test "build rename-and-recreate during lock acquisition fails closed" {
  {
    printf '#!/bin/bash\n'
    printf 'if [[ "$1" == "--version" ]]; then exec /usr/bin/flock "$@"; fi\n'
    swap_build_directory_snippet
    printf 'exec /usr/bin/flock "$@"\n'
  } > "$FAKE_BIN/flock"
  chmod +x "$FAKE_BIN/flock"

  run_setup_fixture --no-wine --no-yabridge

  [ "$status" -ne 0 ]
  [[ "$output" == *"Build directory was replaced"* ]]
  [ -e "$BATS_TEST_TMPDIR/build-swapped" ]
  [ ! -e "$FIXTURE_ROOT/build/component-state.env" ]
  [ ! -s "$CALLS" ]
}

@test "build rename-and-recreate after lock validation blocks Wine mutation" {
  {
    printf '#!/bin/bash\n'
    swap_build_directory_snippet
    printf 'exit 0\n'
  } > "$FAKE_BIN/pacman"
  chmod +x "$FAKE_BIN/pacman"

  run_setup_fixture --wine-version 11.8 --wine-sha256 "$WINE_SHA" --no-yabridge

  [ "$status" -ne 0 ]
  [[ "$output" == *"Build directory was replaced"* ]]
  [ -e "$BATS_TEST_TMPDIR/build-swapped" ]
  [ ! -e "$FIXTURE_ROOT/build/wine" ]
  [ ! -e "$FIXTURE_ROOT/build/component-state.env" ]
  assert_no_candidate_directories
  ! grep -q '^tar ' "$CALLS"
}

@test "setup rejects a build directory symlink without touching its target" {
  external_build="$BATS_TEST_TMPDIR/external-build"
  mkdir -p "$external_build"
  printf 'external-content\n' > "$external_build/sentinel"
  rm -rf "$FIXTURE_ROOT/build"
  ln -s "$external_build" "$FIXTURE_ROOT/build"

  run_setup_fixture --no-wine --no-yabridge

  [ "$status" -ne 0 ]
  [[ "$output" == *"Build path must be a direct project directory"* ]]
  grep -q '^external-content$' "$external_build/sentinel"
  [ ! -s "$CALLS" ]
}
