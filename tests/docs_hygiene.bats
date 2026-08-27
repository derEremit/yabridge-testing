#!/usr/bin/env bats

load test_helper

@test "README does not claim the original prefix is physically untouched" {
  refute grep -Eq 'physically never (touched|modified)' "$PROJECT_ROOT/README.md"
}

@test "README names residual risks and the check script" {
  grep -q '## Residual risks' "$PROJECT_ROOT/README.md"
  grep -q './scripts/check.sh' "$PROJECT_ROOT/README.md"
}

@test "setup completion banner leads with probe" {
  grep -q './test.sh probe' "$PROJECT_ROOT/setup.sh"
  refute grep -q './test.sh validate' "$PROJECT_ROOT/setup.sh"
}
