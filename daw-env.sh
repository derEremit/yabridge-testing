#!/bin/bash
# daw-env.sh — Launch a DAW with test wine 11.8 + test yabridge against a
#              copy-on-write CLONE of your real Wine prefix.
#
# YOUR ORIGINAL PREFIXES ARE NEVER TOUCHED.
#
# How it stays safe:
#   - Your real prefix (default: ~/.audio-production/winplugins) is reflink-
#     cloned into prefix-copy/. Reflink = btrfs copy-on-write: the clone shares
#     data extents with the original until something writes. Cloning only
#     READS the original.
#   - WINEPREFIX is exported pointing at the clone. yabridge's find_wine_prefix()
#     honours WINEPREFIX as an override for ALL plugins (see
#     src/plugin/utils.cpp), so no plugin ever resolves back to a real prefix.
#   - Wine 11.8 will auto-upgrade the prefix on first run (registry + system
#     DLLs). That upgrade — and every plugin write — lands on COW extents in
#     prefix-copy/. The original prefix's blocks are physically never modified.
#   - No backups, no restores, no cleanup, no traps. Nothing to go wrong on exit.
#
# The clone persists between runs (so the one-time wine upgrade isn't repeated
# and plugin state survives). Use --fresh to re-clone, --clean to delete it.
#
# Requirements:
#   - /home on btrfs (or any FS with reflink). Verified: yes.
#   - ./setup.sh run at least once (builds yabridge, downloads wine 11.8).
#   - DAW installed natively (not flatpak/snap).
#
# Usage:
#   ./daw-env.sh reaper
#   ./daw-env.sh bitwig-studio
#   ./daw-env.sh reaper /path/to/project.rpp
#   ./daw-env.sh --fresh reaper            # re-clone the prefix first
#   ./daw-env.sh --prefix ~/.wine reaper   # clone a different real prefix
#   ./daw-env.sh --clean                   # delete prefix-copy/ and exit

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
COPY="$ROOT/prefix-copy"
REAL_PREFIX="$HOME/.audio-production/winplugins"
FRESH=false

require_option_value() {
    local option="$1"
    local value="${2:-}"
    if [[ -z "$value" ]]; then
        echo "Error: $option requires a value" >&2
        exit 2
    fi
}

# ── Parse options ────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --fresh)   FRESH=true; shift ;;
        --prefix)
            require_option_value "--prefix" "${2:-}"
            REAL_PREFIX="$2"
            shift 2
            ;;
        --clean)   echo "Removing $COPY..."; rm -rf "$COPY"; echo "Done."; exit 0 ;;
        -h|--help)
            sed -n '2,33p' "$0" | sed 's/^# \?//'
            exit 0 ;;
        --) shift; break ;;
        -*) echo "Unknown option: $1" >&2; exit 1 ;;
        *)  break ;;
    esac
done

DAW="${1:-}"
if [[ -z "$DAW" ]]; then
    echo "Usage: $0 [--fresh] [--prefix DIR] <daw-binary> [args...]"
    echo "       $0 --clean"
    exit 1
fi
shift 1

if ! command -v "$DAW" &>/dev/null; then
    echo "Error: '$DAW' not found in PATH" >&2
    exit 1
fi

# ── Resolve the real prefix (collapses ~/winplugins -> .audio-production/...) ─
if [[ ! -d "$REAL_PREFIX" ]]; then
    echo "Error: real prefix not found: $REAL_PREFIX" >&2
    exit 1
fi
REAL_PREFIX="$(realpath "$REAL_PREFIX")"
if [[ ! -f "$REAL_PREFIX/system.reg" ]]; then
    echo "Error: $REAL_PREFIX does not look like a Wine prefix (no system.reg)" >&2
    exit 1
fi

# ── Clone the real prefix (reflink / copy-on-write) ──────────────────────────
if [[ "$FRESH" == true ]]; then
    rm -rf "$COPY"
fi

if [[ -d "$COPY" ]]; then
    echo "Reusing existing clone: $COPY (created $(date -r "$COPY" '+%Y-%m-%d %H:%M'))"
    echo "  (use --fresh to re-clone from $REAL_PREFIX)"
else
    echo "Cloning $REAL_PREFIX -> $COPY"
    echo "  reflink copy-on-write — instant, near-zero disk, original only READ..."
    # --reflink=always: fail loudly rather than silently doing a 42G real copy.
    # -a: preserve symlinks (dosdevices/), perms, timestamps, xattrs.
    if ! cp -a --reflink=always "$REAL_PREFIX" "$COPY"; then
        echo "" >&2
        echo "Error: reflink clone failed. This needs the project dir and the" >&2
        echo "real prefix on the SAME btrfs/XFS filesystem. Aborting WITHOUT" >&2
        echo "falling back to a plain copy — your original is untouched." >&2
        rm -rf "$COPY"
        exit 1
    fi
    echo "  Clone ready."
fi

# ── Build the environment ────────────────────────────────────────────────────
# env.sh sets WINELOADER/WINESERVER/WINEDLLPATH/PATH/LD_LIBRARY_PATH (wine 11.8
# + test yabridge) and also WINEPREFIX=prefix/ — we override that below.
source "$ROOT/env.sh"
export WINEPREFIX="$COPY"

# ── Safety assertion: WINEPREFIX must be the clone, never a real prefix ───────
WP_REAL="$(realpath "$WINEPREFIX")"
if [[ "$WP_REAL" != "$(realpath "$COPY")" ]]; then
    echo "Error: WINEPREFIX is not the clone ($WP_REAL) — refusing to launch." >&2
    exit 1
fi
for guard in "$HOME/.audio-production/winplugins" "$HOME/winplugins" "$HOME/.wine"; do
    [[ -e "$guard" ]] || continue
    if [[ "$WP_REAL" == "$(realpath "$guard")" ]]; then
        echo "Error: WINEPREFIX resolves to a REAL prefix ($guard) — refusing." >&2
        exit 1
    fi
done

# ── Launch ───────────────────────────────────────────────────────────────────
echo ""
echo "Launching $DAW with:"
echo "  WINELOADER:  $WINELOADER ($(wine --version 2>/dev/null || echo '?'))"
echo "  yabridge:    $(git -C "$ROOT/build/yabridge-src" rev-parse --short HEAD 2>/dev/null || echo '?')"
echo "  WINEPREFIX:  $WINEPREFIX  (COW clone of $REAL_PREFIX)"
echo "  Original prefix is read-only-shared via COW — physically never modified."
echo ""

exec "$DAW" "$@"
