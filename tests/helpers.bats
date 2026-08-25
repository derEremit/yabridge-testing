#!/usr/bin/env bats
#
# The shared test helpers themselves. An absence assertion that cannot fail is
# worse than no assertion at all: it reads like proof while proving nothing, so
# the helper every suite uses to state absence is tested here directly.

load test_helper

setup() {
  LOG="$BATS_TEST_TMPDIR/log"
  printf 'present\n' > "$LOG"
  DIRECTORY="$BATS_TEST_TMPDIR/directory"
  mkdir -p "$DIRECTORY"
}

# ── refute ───────────────────────────────────────────────────────────────────

@test "refute accepts the one status that proves an absence" {
  run refute grep -q 'absent' "$LOG"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "refute rejects a command that found the forbidden match" {
  run refute grep -q 'present' "$LOG"

  [ "$status" -ne 0 ]
  [[ "$output" == *"succeeded"* ]]
  [[ "$output" == *"grep -q present $LOG"* ]]
}

# A missing file is the failure mode that matters most: the suites refute
# against call logs and recorded environments that only exist if the run under
# test got far enough to write them.
@test "refute refuses to accept a missing file as an absence" {
  run refute grep -q 'anything' "$BATS_TEST_TMPDIR/never-written"

  [ "$status" -ne 0 ]
  [[ "$output" == *"could not answer"* ]]
  [[ "$output" == *"status: 2"* ]]
  [[ "$output" == *"No such file or directory"* ]]
}

@test "refute refuses to accept an unreadable input as an absence" {
  run refute grep -q 'anything' "$DIRECTORY"

  [ "$status" -ne 0 ]
  [[ "$output" == *"status: 2"* ]]
  [[ "$output" == *"Is a directory"* ]]
}

@test "refute refuses to accept a misspelled command as an absence" {
  run refute grpe -q 'anything' "$LOG"

  [ "$status" -ne 0 ]
  [[ "$output" == *"status: 127"* ]]
  [[ "$output" == *"grpe"* ]]
}

@test "refute reports an absent glob without a shell error" {
  run refute compgen -G "$BATS_TEST_TMPDIR/no-such-candidate.*"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "refute rejects a glob that matches" {
  printf '%s\n' 'candidate' > "$BATS_TEST_TMPDIR/no-such-candidate.1"

  run refute compgen -G "$BATS_TEST_TMPDIR/no-such-candidate.*"

  [ "$status" -ne 0 ]
  [[ "$output" == *"succeeded"* ]]
}
