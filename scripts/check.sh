#!/bin/bash
set -euo pipefail
ROOT="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
cd "$ROOT"

shellcheck setup.sh daw-env.sh test.sh scripts/check.sh lib/*.sh
bats tests

WEB_PY="$ROOT/yabridge-test-infra/web/.venv/bin/python"
if [[ -x "$WEB_PY" ]]; then
    (cd "$ROOT/yabridge-test-infra/web" && "$WEB_PY" -m pytest -q && "$WEB_PY" -m mypy app && "$WEB_PY" -m ruff check app tests)
else
    echo "skip: web venv not present"
fi

HARNESS_PY="$ROOT/yabridge-test-infra/test-harness/.venv/bin/python"
if [[ -x "$HARNESS_PY" ]]; then
    (cd "$ROOT/yabridge-test-infra/test-harness" && "$HARNESS_PY" -m pytest -q -m "not native_probe and not wine_probe and not live_probe")
else
    echo "skip: harness venv not present"
fi
