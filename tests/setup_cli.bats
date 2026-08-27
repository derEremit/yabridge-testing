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

@test "setup rejects a missing yabridge branch" {
  run_setup --yabridge-branch
  [ "$status" -eq 2 ]
  [[ "$output" == *"--yabridge-branch requires a value"* ]]
}

@test "setup rejects an option token as wine version" {
  run_setup --wine-version --help
  [ "$status" -eq 2 ]
  [[ "$output" == *"--wine-version requires a value"* ]]
}

@test "setup rejects an option token as yabridge branch" {
  run_setup --yabridge-branch --no-wine
  [ "$status" -eq 2 ]
  [[ "$output" == *"--yabridge-branch requires a value"* ]]
}

@test "DAW launcher rejects a missing prefix value" {
  run_daw_env --prefix
  [ "$status" -eq 2 ]
  [[ "$output" == *"--prefix requires a value"* ]]
}

@test "DAW launcher rejects an option token as prefix value" {
  run_daw_env --prefix --fresh
  [ "$status" -eq 2 ]
  [[ "$output" == *"--prefix requires a value"* ]]
}

@test "test.sh help exits successfully without env.sh" {
  run "$PROJECT_ROOT/test.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"probe"* ]]
}

@test "test.sh -h exits successfully without env.sh" {
  run "$PROJECT_ROOT/test.sh" -h
  [ "$status" -eq 0 ]
}

@test "DAW launcher help exits successfully" {
  run_daw_env --help
  [ "$status" -eq 0 ]
}
