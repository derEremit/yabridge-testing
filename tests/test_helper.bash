PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

# Every library daw-env.sh sources. Fixtures copy the whole set, so adding a
# helper cannot leave a fixture launcher unable to start for a reason that has
# nothing to do with what the suite is testing.
LAUNCHER_LIBRARIES=(
  component-state.sh
  clone-state.sh
  isolated-bridges.sh
  sandbox.sh
  run-manifest.sh
)

# The component identities setup.sh records. A launch refuses to start without
# them, because the run manifest has to name the exact Wine and yabridge build
# the run used.
FIXTURE_WINE_VERSION="11.8"
# Read by the suites, not by this file.
# shellcheck disable=SC2034
FIXTURE_WINE_VERSION_STRING="wine-11.8 (Staging)"
FIXTURE_WINE_SHA256="6c6f642b0954248493ebbd86ec232c46a6b9cf97c747ab3f1bcb707a22efed1d"
FIXTURE_YABRIDGE_REF="master"
FIXTURE_YABRIDGE_COMMIT="48ea9749b682c48875366134a42073d6b3d0a8c4"

# Bash exempts a command whose status is inverted with `!` from errexit, so a
# bare `! grep ...` line inside a bats test can never fail the test. Absence
# claims go through this helper instead, where the status is real.
#
# Exactly one status proves an absence: 1, meaning the command ran and did not
# find what it was told to look for. Status 0 found it. Anything above 1 means
# the command could not answer the question at all — a missing call log, an
# unreadable input, a misspelled command name — and that is reported as a
# failure with the status and the command's own stderr, because silently
# treating "I could not look" as "it is not there" is how a suite ends up
# proving nothing.
refute() {
  local status=0
  local stderr
  stderr="$( { "$@" > /dev/null; } 2>&1 )" || status=$?

  case "$status" in
    0)
      printf 'expected to fail but succeeded: %s\n' "$*" >&2
      return 1
      ;;
    1) return 0 ;;
    *)
      printf 'command could not answer the absence it was asked about\n' >&2
      printf '  command: %s\n' "$*" >&2
      printf '  status: %s\n' "$status" >&2
      if [[ -n "$stderr" ]]; then
        printf '  stderr: %s\n' "$stderr" >&2
      fi
      return 1
      ;;
  esac
}

# One value out of the environment a fixture DAW recorded. The file exists only
# if the DAW actually ran, and a missing key means it ran without that variable,
# so both are reported rather than returned as an empty string. Suites rely on
# these assertions as proof that a launch happened, and an absence assertion
# about the same file is only meaningful once the file is known to be there.
daw_env_value() {
  local key="$1"
  local line
  if [[ ! -f "${DAW_ENV_FILE:?}" ]]; then
    printf 'the fixture DAW recorded no environment at all: %s\n' \
      "$DAW_ENV_FILE" >&2
    return 1
  fi
  if ! line="$(grep -m1 -- "^$key=" "$DAW_ENV_FILE")"; then
    printf 'the fixture DAW recorded no %s in %s\n' "$key" "$DAW_ENV_FILE" >&2
    return 1
  fi
  printf '%s\n' "${line#"$key"=}"
}

# A command that always fails, on a directory meant to be prepended to PATH.
# Lets a suite observe how the code under test handles a tool that cannot answer
# — an encoder, a rename, a `stat` — without depending on file permissions,
# which root would ignore anyway.
shadow_failing_command() {
  local name="$1"
  local directory="$BATS_TEST_TMPDIR/broken-bin"
  mkdir -p "$directory"
  cat > "$directory/$name" <<'EOF'
#!/bin/bash
printf 'fixture: refusing to run\n' >&2
exit 1
EOF
  chmod +x "$directory/$name"
  printf '%s\n' "$directory"
}

run_setup() {
  run "$PROJECT_ROOT/setup.sh" "$@"
}

run_daw_env() {
  run "$PROJECT_ROOT/daw-env.sh" "$@"
}

copy_launcher_libraries() {
  local destination="$1"
  local helper
  mkdir -p "$destination"
  for helper in "${LAUNCHER_LIBRARIES[@]}"; do
    if [[ -f "$PROJECT_ROOT/lib/$helper" ]]; then
      cp "$PROJECT_ROOT/lib/$helper" "$destination/$helper"
    fi
  done
}

seed_component_state_file() {
  local file="$1"
  mkdir -p "$(dirname -- "$file")"
  printf 'WINE_VERSION=%s\nWINE_SHA256=%s\nWINE_SHA256_VERIFIED=true\nYABRIDGE_REF=%s\nYABRIDGE_COMMIT=%s\n' \
    "$FIXTURE_WINE_VERSION" "$FIXTURE_WINE_SHA256" "$FIXTURE_YABRIDGE_REF" \
    "$FIXTURE_YABRIDGE_COMMIT" > "$file"
}

# A stand-in for an executable that only has to answer `--version`, so a suite
# can state exactly which Wine a fixture claims to be.
write_version_command() {
  local path="$1"
  local version="$2"
  mkdir -p "$(dirname -- "$path")"
  cat > "$path" <<EOF
#!/bin/bash
printf '%s\n' "$version"
EOF
  chmod +x "$path"
}

# Writes a fake bwrap that records its exact argv, applies the --setenv values
# it was given, and executes the command after the argument separator. It never
# mounts anything, so suites that only cover clone or bridge behavior stay
# independent of host kernel namespace policy. Suites must export
# SANDBOX_TEST_BWRAP_CALLS; SANDBOX_TEST_BWRAP_FAIL and
# SANDBOX_TEST_BWRAP_FAIL_USERNS simulate an unusable sandbox.
write_fake_bwrap() {
  local path="$1"
  cat > "$path" <<'FAKE_BWRAP'
#!/bin/bash
{
  printf 'argv'
  printf ' %q' "$@"
  printf '\n'
} >> "${SANDBOX_TEST_BWRAP_CALLS:?}"
if [[ "${SANDBOX_TEST_BWRAP_FAIL:-false}" == true ]]; then
  printf 'bwrap: No permissions to creating new namespace\n' >&2
  exit 1
fi
declare -a sandbox_command=()
declare -a sandbox_environment=()
separator=false
while [[ $# -gt 0 ]]; do
  if [[ "$separator" == true ]]; then
    sandbox_command+=("$1")
    shift
    continue
  fi
  case "$1" in
    --)
      separator=true
      shift
      ;;
    --unshare-user)
      if [[ "${SANDBOX_TEST_BWRAP_FAIL_USERNS:-false}" == true ]]; then
        printf 'bwrap: setting up uid map: Permission denied\n' >&2
        exit 1
      fi
      shift
      ;;
    --setenv)
      sandbox_environment+=("$2=$3")
      shift 3
      ;;
    *) shift ;;
  esac
done
if [[ "$separator" != true || "${#sandbox_command[@]}" -eq 0 ]]; then
  printf 'bwrap: no command to execute\n' >&2
  exit 1
fi
for assignment in ${sandbox_environment[@]+"${sandbox_environment[@]}"}; do
  export "${assignment%%=*}=${assignment#*=}"
done
exec "${sandbox_command[@]}"
FAKE_BWRAP
  chmod +x "$path"
}
