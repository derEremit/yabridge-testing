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

@test "daw-env.sh does not claim the original prefix is physically untouched" {
  refute grep -Eq 'physically never' "$PROJECT_ROOT/daw-env.sh"
}

@test "setup env comment does not claim the original prefix is only read" {
  refute grep -q 'only read, never written' "$PROJECT_ROOT/setup.sh"
}

@test "daw-env.sh does not shout that prefixes are never touched" {
  refute grep -F 'YOUR ORIGINAL PREFIXES ARE NEVER TOUCHED' "$PROJECT_ROOT/daw-env.sh"
}

@test "check.sh is executable and lists shellcheck and bats" {
  [ -x "$PROJECT_ROOT/scripts/check.sh" ]
  grep -q shellcheck "$PROJECT_ROOT/scripts/check.sh"
  grep -q bats "$PROJECT_ROOT/scripts/check.sh"
}

@test "setup.sh writes the same test.sh body it ships" {
  local generated
  generated="$(awk '/^cat > "\$ROOT\/test.sh" << '\''TESTEOF'\''$/{p=1; next} /^TESTEOF$/{exit} p' \
    "$PROJECT_ROOT/setup.sh")"
  [ "$generated" = "$(cat "$PROJECT_ROOT/test.sh")" ]
}
