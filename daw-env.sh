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
#   - Clone creation uses a temporary sibling and atomic rename. Failed copies
#     remove only that invocation's temporary clone.
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
#   ./daw-env.sh --refresh-bridges reaper  # refresh bridges, reuse the clone
#   ./daw-env.sh --prefix ~/.wine reaper   # clone a different real prefix
#   ./daw-env.sh --clean                   # delete prefix-copy/ and exit

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
COPY="$ROOT/prefix-copy"
REAL_PREFIX="$HOME/.audio-production/winplugins"
FRESH=false
CLEAN=false
REFRESH_BRIDGES=false

source "$ROOT/lib/clone-state.sh"

require_option_value() {
    local option="$1"
    local value="${2:-}"
    if [[ -z "$value" || "$value" == -* ]]; then
        echo "Error: $option requires a value" >&2
        exit 2
    fi
}

# ── Parse options ────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --fresh)   FRESH=true; shift ;;
        --refresh-bridges) REFRESH_BRIDGES=true; shift ;;
        --prefix)
            require_option_value "--prefix" "${2:-}"
            REAL_PREFIX="$2"
            shift 2
            ;;
        --clean)   CLEAN=true; shift ;;
        -h|--help)
            sed -n '2,36p' "$0" | sed 's/^# \?//'
            exit 0 ;;
        --) shift; break ;;
        -*) echo "Unknown option: $1" >&2; exit 1 ;;
        *)  break ;;
    esac
done
export YABRIDGE_STAGING_REFRESH_BRIDGES="$REFRESH_BRIDGES"

DAW="${1:-}"
if [[ "$CLEAN" != true && -z "$DAW" ]]; then
    echo "Usage: $0 [--fresh] [--refresh-bridges] [--prefix DIR] <daw-binary> [args...]"
    echo "       $0 --clean"
    exit 1
fi
if [[ "$CLEAN" != true ]]; then
    shift 1
fi

if [[ "$CLEAN" != true ]] && ! command -v "$DAW" &>/dev/null; then
    echo "Error: '$DAW' not found in PATH" >&2
    exit 1
fi

# ── Resolve the real prefix (collapses ~/winplugins -> .audio-production/...) ─
if [[ ! -d "$REAL_PREFIX" ]]; then
    echo "Error: real prefix not found: $REAL_PREFIX" >&2
    exit 1
fi
REAL_PREFIX="$(realpath "$REAL_PREFIX")"
if [[ "$REAL_PREFIX" == *$'\n'* || "$REAL_PREFIX" == *$'\r'* ]]; then
    echo "Error: source prefix path contains an unsupported newline" >&2
    exit 1
fi
if [[ ! -f "$REAL_PREFIX/system.reg" ]]; then
    echo "Error: $REAL_PREFIX does not look like a Wine prefix (no system.reg)" >&2
    exit 1
fi

# ── Clone the real prefix (reflink / copy-on-write) ──────────────────────────
assert_separate_clone_paths "$REAL_PREFIX" "$COPY"
assert_clone_destination_type "$COPY"
acquire_clone_lock "$ROOT"
trap release_clone_lock EXIT

clone_exists=false
if validate_clone_provenance "$COPY" "$REAL_PREFIX"; then
    clone_exists=true
else
    clone_status=$?
    if [[ "$clone_status" -ne 2 ]]; then
        exit 1
    fi
fi

if [[ "$CLEAN" == true ]]; then
    if [[ "$clone_exists" == true ]]; then
        echo "Removing $COPY..."
        remove_validated_clone "$COPY"
        echo "Done."
    else
        echo "No clone to remove: $COPY"
    fi
    release_clone_lock
    trap - EXIT
    exit 0
fi

if [[ "$clone_exists" == true && "$FRESH" != true ]]; then
    echo "Reusing existing clone: $COPY (created $(date -r "$COPY" '+%Y-%m-%d %H:%M'))"
    echo "  (use --fresh to re-clone from $REAL_PREFIX)"
else
    clone_prefix_atomic "$REAL_PREFIX" "$COPY" "$clone_exists"
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

validate_clone_provenance "$COPY" "$REAL_PREFIX"
release_clone_lock
trap - EXIT

# ── Launch ───────────────────────────────────────────────────────────────────
echo ""
echo "Launching $DAW with:"
echo "  WINELOADER:  $WINELOADER ($(wine --version 2>/dev/null || echo '?'))"
echo "  yabridge:    $(git -C "$ROOT/build/yabridge-src" rev-parse --short HEAD 2>/dev/null || echo '?')"
echo "  WINEPREFIX:  $WINEPREFIX  (COW clone of $REAL_PREFIX)"
echo "  Original prefix is read-only-shared via COW — physically never modified."
echo ""

exec "$DAW" "$@"
