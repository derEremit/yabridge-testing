#!/bin/bash
# Keep the bwrap command alive after wine's first process exits.
# XLN's updater ShellExecute's a replacement exe and quits; without
# wineserver -w the sandbox tears down and that child dies with it.
set -u
if [[ $# -lt 1 ]]; then
    echo "Usage: wine-wait.sh WINE [args...]" >&2
    exit 1
fi
wine="$1"
shift
status=0
"$wine" "$@" || status=$?
if [[ -n "${WINESERVER:-}" && -x "$WINESERVER" ]]; then
    "$WINESERVER" -w || true
fi
exit "$status"
