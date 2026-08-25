PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

run_setup() {
  run "$PROJECT_ROOT/setup.sh" "$@"
}

run_daw_env() {
  run "$PROJECT_ROOT/daw-env.sh" "$@"
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
