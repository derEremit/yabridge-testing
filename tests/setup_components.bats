#!/usr/bin/env bats

load test_helper

WINE_11_8_SHA="6c6f642b0954248493ebbd86ec232c46a6b9cf97c747ab3f1bcb707a22efed1d"
OLD_WINE_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
WRONG_WINE_SHA="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
YABRIDGE_COMMIT="48ea9749b682c48875366134a42073d6b3d0a8c4"

setup() {
  FIXTURE="$BATS_TEST_TMPDIR/project"
  FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  CALLS="$BATS_TEST_TMPDIR/calls"
  mkdir -p \
    "$FIXTURE/lib" \
    "$FIXTURE/build" \
    "$FIXTURE/prefix" \
    "$FIXTURE/yabridge-test-infra" \
    "$FAKE_BIN"
  cp "$PROJECT_ROOT/setup.sh" "$FIXTURE/setup.sh"
  cp "$PROJECT_ROOT/lib/component-state.sh" "$FIXTURE/lib/component-state.sh"
  cp -R \
    "$PROJECT_ROOT/yabridge-test-infra/test-harness" \
    "$FIXTURE/yabridge-test-infra/test-harness"
  touch "$FIXTURE/prefix/system.reg" "$CALLS"
  create_fake_commands
}

create_fake_commands() {
  cat > "$FAKE_BIN/pacman" <<'EOF'
#!/bin/bash
exit 0
EOF

  cat > "$FAKE_BIN/curl" <<'EOF'
#!/bin/bash
printf 'curl %s\n' "$*" >> "$CALLS"
[[ "$FAKE_CURL_FAIL" == true ]] && exit 22
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-o" ]]; then
    printf 'fake archive\n' > "$2"
    exit 0
  fi
  shift
done
EOF

  cat > "$FAKE_BIN/sha256sum" <<'EOF'
#!/bin/bash
if [[ "$1" == "-c" ]]; then
  read -r expected archive
  if [[ "$expected" == "$FAKE_SHA" ]]; then
    printf '%s: OK\n' "$archive"
    exit 0
  fi
  printf '%s: FAILED\n' "$archive"
  exit 1
fi
printf '%s  %s\n' "$FAKE_SHA" "${!#}"
EOF

  cat > "$FAKE_BIN/tar" <<'EOF'
#!/bin/bash
printf 'tar %s\n' "$*" >> "$CALLS"
[[ "$FAKE_TAR_FAIL" == true ]] && exit 1
if [[ "$1" == "-tf" ]]; then
  printf 'wine-11.8-staging-amd64/bin/wine\n'
  exit 0
fi
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-C" ]]; then
    build="$2"
    break
  fi
  shift
done
wine="$build/wine-11.8-staging-amd64"
mkdir -p "$wine/bin"
for command in wine wineboot wineserver; do
  if [[ "$command" == wine && "$FAKE_CANDIDATE_INVALID" == true ]]; then
    printf '#!/bin/bash\nexit 1\n' > "$wine/bin/$command"
  else
    printf '#!/bin/bash\nexit 0\n' > "$wine/bin/$command"
  fi
  chmod +x "$wine/bin/$command"
done
EOF

  cat > "$FAKE_BIN/git" <<'EOF'
#!/bin/bash
printf 'git %s\n' "$*" >> "$CALLS"
if [[ "$*" == *"rev-parse"*"FETCH_HEAD"* ]]; then
  printf '%s\n' "$FAKE_YABRIDGE_FETCH_COMMIT"
elif [[ "$*" == *"rev-parse"*"HEAD"* ]]; then
  printf '%s\n' "$FAKE_YABRIDGE_HEAD_COMMIT"
fi
EOF

  cat > "$FAKE_BIN/meson" <<'EOF'
#!/bin/bash
printf 'meson %s\n' "$*" >> "$CALLS"
if [[ "$1" == "setup" ]]; then
  shift
  [[ "$1" == "--wipe" ]] && shift
  for argument in "$@"; do
    [[ "$argument" == */build ]] && mkdir -p "$argument"
  done
fi
exit 0
EOF

  cat > "$FAKE_BIN/ninja" <<'EOF'
#!/bin/bash
printf 'ninja %s\n' "$*" >> "$CALLS"
if [[ "$1" == "-C" ]]; then
  mkdir -p "$2"
  touch "$2/libyabridge-vst2.so" "$2/yabridge-host.exe"
fi
EOF

  cat > "$FAKE_BIN/python3" <<'EOF'
#!/bin/bash
if [[ "$1" == "-m" && "$2" == "venv" ]]; then
  mkdir -p "$3/bin"
  cp "$0" "$3/bin/python"
  chmod +x "$3/bin/python"
  exit 0
fi
if [[ "$1" == "-m" && "$2" == "pip" ]]; then
  venv_bin="$(cd "$(dirname "$0")" && pwd)"
  printf '#!/bin/bash\nexit 0\n' > "$venv_bin/yabridge-test"
  chmod +x "$venv_bin/yabridge-test"
  exit 0
fi
exit 1
EOF

  chmod +x "$FAKE_BIN"/*
}

seed_component_state() {
  local key="$1" value="$2"
  printf '%s=%s\n' "$key" "$value" > "$FIXTURE/build/component-state.env"
}

seed_wine_cache() {
  mkdir -p "$FIXTURE/build/wine/bin"
  for command in wine wineboot wineserver; do
    printf '#!/bin/bash\nexit 0\n' > "$FIXTURE/build/wine/bin/$command"
    chmod +x "$FIXTURE/build/wine/bin/$command"
  done
  touch "$FIXTURE/build/wine/prior-install"
}

seed_wine_state() {
  printf 'WINE_VERSION=11.8\nWINE_SHA256=%s\n' "$OLD_WINE_SHA" \
    > "$FIXTURE/build/component-state.env"
}

assert_prior_wine_preserved() {
  [ -x "$FIXTURE/build/wine/bin/wine" ]
  [ -f "$FIXTURE/build/wine/prior-install" ]
  grep -q "WINE_SHA256=$OLD_WINE_SHA" "$FIXTURE/build/component-state.env"
}

seed_yabridge_cache() {
  mkdir -p "$FIXTURE/build/yabridge-src/build" "$FIXTURE/build/yabridge"
  touch "$FIXTURE/build/yabridge/libyabridge-vst2.so"
  touch "$FIXTURE/build/yabridge/yabridge-host.exe"
}

run_setup_fixture() {
  run env \
    PATH="$FAKE_BIN:$PATH" \
    CALLS="$CALLS" \
    FAKE_SHA="${FAKE_SHA_VALUE:-$WINE_11_8_SHA}" \
    FAKE_CURL_FAIL="${FAKE_CURL_FAIL:-false}" \
    FAKE_TAR_FAIL="${FAKE_TAR_FAIL:-false}" \
    FAKE_CANDIDATE_INVALID="${FAKE_CANDIDATE_INVALID:-false}" \
    FAKE_YABRIDGE_FETCH_COMMIT="${FAKE_YABRIDGE_FETCH_COMMIT:-$YABRIDGE_COMMIT}" \
    FAKE_YABRIDGE_HEAD_COMMIT="${FAKE_YABRIDGE_HEAD_COMMIT:-$YABRIDGE_COMMIT}" \
    "$FIXTURE/setup.sh" "$@"
}

@test "explicit Wine version requires a digest" {
  run_setup_fixture --no-yabridge --wine-version 11.8

  [ "$status" -eq 2 ]
  [[ "$output" == *"--wine-sha256 is required with --wine-version"* ]]
}

@test "different requested Wine version replaces cached Wine" {
  seed_wine_cache
  seed_component_state WINE_VERSION 11.7

  run_setup_fixture --no-yabridge --wine-version 11.8 --wine-sha256 "$WINE_11_8_SHA"

  [ "$status" -eq 0 ]
  grep -q "curl .*wine-11.8-staging-amd64.tar.xz" "$CALLS"
}

@test "different requested digest refreshes the same Wine version" {
  seed_wine_cache
  seed_wine_state

  run_setup_fixture --no-yabridge --wine-version 11.8 --wine-sha256 "$WINE_11_8_SHA"

  [ "$status" -eq 0 ]
  grep -q "curl .*wine-11.8-staging-amd64.tar.xz" "$CALLS"
  grep -q "WINE_SHA256=$WINE_11_8_SHA" "$FIXTURE/build/component-state.env"
  [ ! -e "$FIXTURE/build/wine/prior-install" ]
}

@test "wrong downloaded digest is rejected without replacing Wine" {
  seed_wine_cache
  seed_wine_state
  FAKE_SHA_VALUE="$WRONG_WINE_SHA"

  run_setup_fixture --no-yabridge --wine-version 11.8 --wine-sha256 "$WINE_11_8_SHA"

  [ "$status" -eq 1 ]
  [[ "$output" == *"Wine archive checksum mismatch"* ]]
  assert_prior_wine_preserved
}

@test "Wine download failure preserves the existing installation" {
  seed_wine_cache
  seed_wine_state
  FAKE_CURL_FAIL=true

  run_setup_fixture --no-yabridge --wine-version 11.8 --wine-sha256 "$WINE_11_8_SHA"

  [ "$status" -eq 1 ]
  assert_prior_wine_preserved
}

@test "Wine extraction failure preserves the existing installation" {
  seed_wine_cache
  seed_wine_state
  FAKE_TAR_FAIL=true

  run_setup_fixture --no-yabridge --wine-version 11.8 --wine-sha256 "$WINE_11_8_SHA"

  [ "$status" -eq 1 ]
  assert_prior_wine_preserved
}

@test "invalid Wine candidate preserves the existing installation" {
  seed_wine_cache
  seed_wine_state
  FAKE_CANDIDATE_INVALID=true

  run_setup_fixture --no-yabridge --wine-version 11.8 --wine-sha256 "$WINE_11_8_SHA"

  [ "$status" -eq 1 ]
  assert_prior_wine_preserved
}

@test "different yabridge ref fetches and rebuilds" {
  seed_yabridge_cache
  seed_component_state YABRIDGE_COMMIT old-commit

  run_setup_fixture --no-wine --yabridge-branch "$YABRIDGE_COMMIT"

  [ "$status" -eq 0 ]
  grep -q "git .*checkout.*48ea974" "$CALLS"
  grep -q "meson setup --wipe $FIXTURE/build/yabridge-src/build $FIXTURE/build/yabridge-src" "$CALLS"
  grep -q "ninja" "$CALLS"
}

@test "moved yabridge branch resolves fetched commit and rebuilds" {
  seed_yabridge_cache
  printf 'YABRIDGE_REF=master\nYABRIDGE_COMMIT=old-commit\n' \
    > "$FIXTURE/build/component-state.env"
  FAKE_YABRIDGE_FETCH_COMMIT="$YABRIDGE_COMMIT"
  FAKE_YABRIDGE_HEAD_COMMIT="old-commit"

  run_setup_fixture --no-wine --yabridge-branch master

  [ "$status" -eq 0 ]
  grep -q "git .*rev-parse FETCH_HEAD" "$CALLS"
  grep -q "git .*checkout.*48ea974" "$CALLS"
  grep -q "ninja" "$CALLS"
}
