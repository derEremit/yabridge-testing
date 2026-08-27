setup_project_fixture() {
  FIXTURE_ROOT="$BATS_TEST_TMPDIR/project"
  FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  CALLS="$BATS_TEST_TMPDIR/calls"
  mkdir -p \
    "$FIXTURE_ROOT/lib" \
    "$FIXTURE_ROOT/build" \
    "$FIXTURE_ROOT/prefix" \
    "$FIXTURE_ROOT/test-harness" \
    "$FAKE_BIN"
  cp "$PROJECT_ROOT/setup.sh" "$FIXTURE_ROOT/setup.sh"
  cp "$PROJECT_ROOT/lib/component-state.sh" "$FIXTURE_ROOT/lib/component-state.sh"
  cp \
    "$PROJECT_ROOT/test-harness/pyproject.toml" \
    "$PROJECT_ROOT/test-harness/README.md" \
    "$FIXTURE_ROOT/test-harness/"
  cp -R \
    "$PROJECT_ROOT/test-harness/src" \
    "$FIXTURE_ROOT/test-harness/src"
  # The call log starts as an existing empty file on purpose: tests that refute
  # a command was ever run are then asking about its contents, not about
  # whether anything created the log at all.
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
    if [[ -n "$FAKE_ARCHIVE_SOURCE" ]]; then
      cp "$FAKE_ARCHIVE_SOURCE" "$2"
    else
      printf 'fake archive\n' > "$2"
    fi
    if [[ "$FAKE_INTERRUPT_PHASE" == before-exchange ]]; then
      kill -TERM "$PPID"
      sleep 1
    fi
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
if [[ -n "$FAKE_ARCHIVE_SOURCE" ]]; then
  exec /usr/bin/tar "$@"
fi
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
if [[ "$1" == "-" ]]; then
  if [[ -n "$FAKE_ARCHIVE_SOURCE" ]]; then
    exec /usr/bin/python3 "$@"
  fi
  while IFS= read -r _; do :; done
  exit 0
fi
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
if [[ " $* " == *" --exchange "* ]]; then
  if [[ "$FAKE_CRASH_DURING_ACTIVATION" == true ]]; then
    kill -KILL "$PPID"
    exit 137
  fi
  if [[ "$FAKE_INTERRUPT_PHASE" == after-exchange ]]; then
    /usr/bin/mv "$@"
    kill -TERM "$PPID"
    sleep 1
    exit 143
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

seed_malicious_archive() {
  local kind="$1"
  local target="$2"
  FAKE_ARCHIVE_SOURCE="$BATS_TEST_TMPDIR/$kind.tar"
  /usr/bin/python3 - "$FAKE_ARCHIVE_SOURCE" "$kind" "$target" <<'PY'
import io
import stat
import sys
import tarfile

archive, kind, target = sys.argv[1:]
root = "wine-11.8-staging-amd64"

with tarfile.open(archive, "w") as output:
    for directory in (root, f"{root}/bin"):
        member = tarfile.TarInfo(directory)
        member.type = tarfile.DIRTYPE
        member.mode = 0o755
        output.addfile(member)

    for command in ("wine", "wineboot", "wineserver"):
        member = tarfile.TarInfo(f"{root}/bin/{command}")
        if command == "wine" and kind in ("symlink", "safe-symlink"):
            member.type = tarfile.SYMTYPE
            member.linkname = target
            member.mode = 0o755
            output.addfile(member)
        elif command == "wine" and kind == "hardlink":
            member.type = tarfile.LNKTYPE
            member.linkname = target
            member.mode = 0o755
            output.addfile(member)
        else:
            payload = b"#!/bin/bash\nexit 0\n"
            member.mode = stat.S_IRUSR | stat.S_IWUSR | stat.S_IXUSR
            member.size = len(payload)
            output.addfile(member, io.BytesIO(payload))

    if kind == "safe-symlink":
        payload = b"#!/bin/bash\nexit 0\n"
        member = tarfile.TarInfo(f"{root}/bin/{target}")
        member.mode = 0o700
        member.size = len(payload)
        output.addfile(member, io.BytesIO(payload))
PY
}

seed_stale_candidate() {
  local name="${1:-.wine-candidate.stale}"
  local path="$FIXTURE_ROOT/build/$name"
  mkdir -p "$path"
  printf 'yabridge-wine-candidate-v1:pre-exchange\n' \
    > "$path/.yabridge-candidate"
  touch "$path/stale-content"
}

run_setup_fixture() {
  run env \
    PATH="$FAKE_BIN:$PATH" \
    CALLS="$CALLS" \
    FAKE_WINE_SHA="${FAKE_WINE_SHA:-6c6f642b0954248493ebbd86ec232c46a6b9cf97c747ab3f1bcb707a22efed1d}" \
    FAKE_CHECKSUM_VALID="${FAKE_CHECKSUM_VALID:-true}" \
    FAKE_ARCHIVE_ENTRIES="${FAKE_ARCHIVE_ENTRIES:-wine-11.8-staging-amd64/bin/wine}" \
    FAKE_ARCHIVE_SOURCE="${FAKE_ARCHIVE_SOURCE:-}" \
    FAKE_CRASH_DURING_ACTIVATION="${FAKE_CRASH_DURING_ACTIVATION:-false}" \
    FAKE_INTERRUPT_PHASE="${FAKE_INTERRUPT_PHASE:-}" \
    "${SETUP_INVOCATION_PATH:-$FIXTURE_ROOT/setup.sh}" "$@"
}
