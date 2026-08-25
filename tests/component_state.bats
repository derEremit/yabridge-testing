#!/usr/bin/env bats

load test_helper

setup() {
  STATE="$BATS_TEST_TMPDIR/component-state.env"
  source "$PROJECT_ROOT/lib/component-state.sh"
}

@test "component state round-trips exact values" {
  write_state "$STATE" \
    "WINE_VERSION=11.8" \
    "WINE_SHA256=6c6f642b0954248493ebbd86ec232c46a6b9cf97c747ab3f1bcb707a22efed1d" \
    "YABRIDGE_COMMIT=48ea9749b682c48875366134a42073d6b3d0a8c4"
  [ "$(read_state WINE_VERSION "$STATE")" = "11.8" ]
  component_matches YABRIDGE_COMMIT 48ea9749b682c48875366134a42073d6b3d0a8c4 "$STATE"
}

@test "state values cannot inject shell syntax" {
  write_state "$STATE" 'WINE_VERSION=$(touch injected)'
  run read_state WINE_VERSION "$STATE"
  [ "$status" -eq 1 ]
  [ ! -e "$BATS_TEST_TMPDIR/injected" ]
}
