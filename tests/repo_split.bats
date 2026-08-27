#!/usr/bin/env bats
load test_helper

@test "setup and test.sh point at top-level test-harness" {
  grep -q 'HARNESS="$ROOT/test-harness"' "$PROJECT_ROOT/setup.sh"
  grep -q 'HARNESS="$ROOT/test-harness"' "$PROJECT_ROOT/test.sh"
  refute grep -q 'yabridge-test-infra/test-harness' "$PROJECT_ROOT/setup.sh"
  refute grep -q 'yabridge-test-infra/test-harness' "$PROJECT_ROOT/test.sh"
}

@test "check.sh has no web suite and uses top-level harness" {
  refute grep -q '/web/' "$PROJECT_ROOT/scripts/check.sh"
  grep -q 'test-harness/.venv/bin/python' "$PROJECT_ROOT/scripts/check.sh"
}

@test "public tree has no gitlink and no web app" {
  refute test -f "$PROJECT_ROOT/.gitmodules"
  refute test -d "$PROJECT_ROOT/web/app"
}

@test "README clones staging without a submodule" {
  grep -q 'github.com/derEremit/yabridge-staging' "$PROJECT_ROOT/README.md"
  refute grep -q 'recurse-submodules' "$PROJECT_ROOT/README.md"
  refute grep -q 'yabridge-test-infra/web' "$PROJECT_ROOT/README.md"
}
