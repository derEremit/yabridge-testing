#!/usr/bin/env bats

load test_helper
load setup_fixture

setup() {
  setup_project_fixture
  cat > "$FAKE_BIN/yabridge-test" <<'EOF'
#!/bin/bash
touch "$GLOBAL_HARNESS_USED"
printf 'global:%s\n' "$*"
EOF
  chmod +x "$FAKE_BIN/yabridge-test"
  GLOBAL_HARNESS_USED="$BATS_TEST_TMPDIR/global-harness-used"
}

install_harness_fixture() {
  run_setup_fixture --no-wine --no-yabridge
  [ "$status" -eq 0 ]
}

@test "setup installs the local harness into its venv deterministically" {
  install_harness_fixture

  [ -x "$FIXTURE_ROOT/test-harness/.venv/bin/yabridge-test" ]
  grep -Fq \
    "python3 -m venv $FIXTURE_ROOT/test-harness/.venv" \
    "$CALLS"
  grep -Fq \
    "python3 -m pip install --disable-pip-version-check -e $FIXTURE_ROOT/test-harness" \
    "$CALLS"
}

@test "test wrapper executes the absolute venv harness" {
  install_harness_fixture

  run env PATH="$FAKE_BIN:$PATH" GLOBAL_HARNESS_USED="$GLOBAL_HARNESS_USED" \
    "$FIXTURE_ROOT/test.sh" info

  [ "$status" -eq 0 ]
  [[ "$output" == *"venv:info"* ]]
  [ ! -e "$GLOBAL_HARNESS_USED" ]
}

@test "test wrapper never falls back to a global command" {
  install_harness_fixture
  rm -f "$FIXTURE_ROOT/test-harness/.venv/bin/yabridge-test"

  run env PATH="$FAKE_BIN:$PATH" GLOBAL_HARNESS_USED="$GLOBAL_HARNESS_USED" \
    "$FIXTURE_ROOT/test.sh" info

  [ "$status" -ne 0 ]
  [[ "$output" == *"test harness is not installed"* ]]
  [ ! -e "$GLOBAL_HARNESS_USED" ]
}
