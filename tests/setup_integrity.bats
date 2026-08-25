#!/usr/bin/env bats

load test_helper
load setup_fixture

WINE_SHA="6c6f642b0954248493ebbd86ec232c46a6b9cf97c747ab3f1bcb707a22efed1d"

setup() {
  setup_project_fixture
}

assert_no_candidate_directories() {
  ! compgen -G "$FIXTURE_ROOT/build/.wine-candidate.*" >/dev/null
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
