#!/bin/bash
set -euo pipefail
ROOT="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
cd "$ROOT"

shellcheck setup.sh daw-env.sh test.sh scripts/check.sh lib/*.sh
bats tests

HARNESS_PY="$ROOT/test-harness/.venv/bin/python"
if [[ -x "$HARNESS_PY" ]]; then
    (cd "$ROOT/test-harness" && "$HARNESS_PY" -m pytest -q -m "not native_probe and not wine_probe and not live_probe")
else
    echo "skip: harness venv not present"
fi
