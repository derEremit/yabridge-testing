PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

run_setup() {
  run "$PROJECT_ROOT/setup.sh" "$@"
}

run_daw_env() {
  run "$PROJECT_ROOT/daw-env.sh" "$@"
}
