#!/usr/bin/env bats

load test_helper

@test "setup help exits successfully" {
  run_setup --help
  [ "$status" -eq 0 ]
}

@test "setup rejects a missing wine version" {
  run_setup --wine-version
  [ "$status" -eq 2 ]
  [[ "$output" == *"--wine-version requires a value"* ]]
}

@test "DAW launcher rejects a missing prefix value" {
  run_daw_env --prefix
  [ "$status" -eq 2 ]
  [[ "$output" == *"--prefix requires a value"* ]]
}
