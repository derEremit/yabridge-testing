setup_project_fixture() {
  FIXTURE_ROOT="$BATS_TEST_TMPDIR/project"
  FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  CALLS="$BATS_TEST_TMPDIR/calls"
  mkdir -p \
    "$FIXTURE_ROOT/lib" \
    "$FIXTURE_ROOT/build" \
    "$FIXTURE_ROOT/prefix" \
    "$FIXTURE_ROOT/yabridge-test-infra" \
    "$FAKE_BIN"
  cp "$PROJECT_ROOT/setup.sh" "$FIXTURE_ROOT/setup.sh"
  cp "$PROJECT_ROOT/lib/component-state.sh" "$FIXTURE_ROOT/lib/component-state.sh"
  cp -R \
    "$PROJECT_ROOT/yabridge-test-infra/test-harness" \
    "$FIXTURE_ROOT/yabridge-test-infra/test-harness"
  touch "$FIXTURE_ROOT/prefix/system.reg" "$CALLS"
  create_setup_fake_commands
}

create_setup_fake_commands() {
  cat > "$FAKE_BIN/pacman" <<'EOF'
#!/bin/bash
exit 0
EOF

  cat > "$FAKE_BIN/curl" <<'EOF'
#!/bin/bash
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
printf 'sha256sum %s\n' "$*" >> "$CALLS"
if [[ "$1" == "-c" ]]; then
  read -r expected archive
  if [[ "$FAKE_CHECKSUM_VALID" == true ]]; then
    printf '%s: OK\n' "$archive"
    exit 0
  fi
  printf '%s: FAILED\n' "$archive"
  exit 1
fi
printf '%s  %s\n' "$FAKE_WINE_SHA" "$1"
EOF

  cat > "$FAKE_BIN/tar" <<'EOF'
#!/bin/bash
printf 'tar %s\n' "$*" >> "$CALLS"
if [[ "$1" == "-tf" ]]; then
  printf '%s\n' "$FAKE_ARCHIVE_ENTRIES"
  exit 0
fi
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-C" ]]; then
    destination="$2"
    break
  fi
  shift
done
wine="$destination/wine-11.8-staging-amd64"
mkdir -p "$wine/bin"
for command in wine wineboot wineserver; do
  printf '#!/bin/bash\nexit 0\n' > "$wine/bin/$command"
  chmod +x "$wine/bin/$command"
done
EOF

  cat > "$FAKE_BIN/python3" <<'EOF'
#!/bin/bash
printf 'python3 %s\n' "$*" >> "$CALLS"
if [[ "$1" == "-m" && "$2" == "venv" ]]; then
  venv="$3"
  mkdir -p "$venv/bin"
  cp "$0" "$venv/bin/python"
  chmod +x "$venv/bin/python"
  exit 0
fi
if [[ "$1" == "-m" && "$2" == "pip" ]]; then
  venv_bin="$(cd "$(dirname "$0")" && pwd)"
  cat > "$venv_bin/yabridge-test" <<'SCRIPT'
#!/bin/bash
printf 'venv:%s\n' "$*"
SCRIPT
  chmod +x "$venv_bin/yabridge-test"
  exit 0
fi
exit 1
EOF

  cat > "$FAKE_BIN/mv" <<'EOF'
#!/bin/bash
if [[ "$FAKE_CRASH_DURING_ACTIVATION" == true ]]; then
  if [[ " $* " == *" --exchange "* ]]; then
    kill -KILL "$PPID"
    exit 137
  fi
  if [[ "${!#}" == */build/wine && "$1" == */wine-11.8-staging-amd64 ]]; then
    kill -KILL "$PPID"
    exit 137
  fi
fi
exec /usr/bin/mv "$@"
EOF

  chmod +x "$FAKE_BIN"/*
}

seed_working_wine() {
  mkdir -p "$FIXTURE_ROOT/build/wine/bin"
  for command in wine wineboot wineserver; do
    printf '#!/bin/bash\nexit 0\n' > "$FIXTURE_ROOT/build/wine/bin/$command"
    chmod +x "$FIXTURE_ROOT/build/wine/bin/$command"
  done
  touch "$FIXTURE_ROOT/build/wine/prior-install"
  printf 'WINE_VERSION=11.8\nWINE_SHA256=%s\n' \
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
    > "$FIXTURE_ROOT/build/component-state.env"
}

run_setup_fixture() {
  run env \
    PATH="$FAKE_BIN:$PATH" \
    CALLS="$CALLS" \
    FAKE_WINE_SHA="${FAKE_WINE_SHA:-6c6f642b0954248493ebbd86ec232c46a6b9cf97c747ab3f1bcb707a22efed1d}" \
    FAKE_CHECKSUM_VALID="${FAKE_CHECKSUM_VALID:-true}" \
    FAKE_ARCHIVE_ENTRIES="${FAKE_ARCHIVE_ENTRIES:-wine-11.8-staging-amd64/bin/wine}" \
    FAKE_CRASH_DURING_ACTIVATION="${FAKE_CRASH_DURING_ACTIVATION:-false}" \
    "$FIXTURE_ROOT/setup.sh" "$@"
}
