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
#   - yabridge bridges are generated inside isolation/home, an isolated
#     HOME/XDG tree. Only the clone is registered with yabridgectl, and every
#     generated Windows target must canonicalize inside prefix-copy/. Your
#     production yabridgectl configuration and bridge directories are never
#     read, written, or exposed to the DAW.
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
#   ./daw-env.sh --clean                   # delete prefix-copy/ + isolation/
#
# Plugin path options:
#   --native-plugin-path DIR   expose an absolute native plugin directory to
#                              the DAW in addition to the isolated bridges.
#                              Repeatable. Nothing else is inherited.
#   --allow-empty              launch even when no bridges were generated.
#                              Fixtures and diagnostics only.

set -euo pipefail

SCRIPT_PATH="$(realpath -- "$0")"
ROOT="$(cd -P -- "$(dirname -- "$SCRIPT_PATH")" && pwd -P)"
COPY="$(realpath -m -- "$ROOT")/prefix-copy"
REAL_PREFIX="$HOME/.audio-production/winplugins"
FRESH=false
CLEAN=false
REFRESH_BRIDGES=false
ALLOW_EMPTY=false
NATIVE_PLUGIN_PATHS=()

source "$ROOT/lib/clone-state.sh"
source "$ROOT/lib/isolated-bridges.sh"

daw_env_cleanup() {
    local status=$?
    trap - EXIT INT TERM
    cleanup_owned_bridge_candidate
    release_clone_lock
    return "$status"
}

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
        --allow-empty) ALLOW_EMPTY=true; shift ;;
        --native-plugin-path)
            require_option_value "--native-plugin-path" "${2:-}"
            validate_native_plugin_path "$2" || exit 2
            NATIVE_PLUGIN_PATHS+=("$2")
            shift 2
            ;;
        --clean)   CLEAN=true; shift ;;
        -h|--help)
            sed -n '2,48p' "$0" | sed 's/^# \?//'
            exit 0 ;;
        --) shift; break ;;
        -*) echo "Unknown option: $1" >&2; exit 1 ;;
        *)  break ;;
    esac
done
export YABRIDGE_STAGING_REFRESH_BRIDGES="$REFRESH_BRIDGES"

DAW="${1:-}"
if [[ "$CLEAN" != true && -z "$DAW" ]]; then
    echo "Usage: $0 [--fresh] [--refresh-bridges] [--allow-empty]"
    echo "          [--native-plugin-path DIR]... [--prefix DIR]"
    echo "          <daw-binary> [args...]"
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
trap daw_env_cleanup EXIT

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
    else
        echo "No clone to remove: $COPY"
    fi
    remove_isolated_bridges "$ROOT"
    echo "Done."
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

# ── Generate bridges that can only reach the clone ────────────────────────────
# clone_prefix_atomic clears its own traps on success, so the composed cleanup
# is reinstalled here to cover both the clone lock and the bridge candidate.
trap daw_env_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

YABRIDGE_HOME="${YABRIDGE_BIN:-$ROOT/build/yabridge}"
YABRIDGECTL="$YABRIDGE_HOME/yabridgectl"
if [[ ! -x "$YABRIDGECTL" ]] && ! YABRIDGECTL="$(command -v yabridgectl)"; then
    echo "Error: yabridgectl not found in $YABRIDGE_HOME or PATH" >&2
    echo "Run ./setup.sh to build it, or install yabridgectl." >&2
    exit 1
fi

ISOLATED_BRIDGES_REFRESH="$REFRESH_BRIDGES"
ISOLATED_BRIDGES_ALLOW_EMPTY="$ALLOW_EMPTY"
prepare_isolated_bridges "$ROOT" "$COPY" "$YABRIDGECTL" "$YABRIDGE_HOME"
export_isolated_plugin_paths ${NATIVE_PLUGIN_PATHS[@]+"${NATIVE_PLUGIN_PATHS[@]}"}

release_clone_lock
trap - EXIT INT TERM

# ── Launch ───────────────────────────────────────────────────────────────────
echo ""
echo "Launching $DAW with:"
echo "  WINELOADER:  $WINELOADER ($(wine --version 2>/dev/null || echo '?'))"
echo "  yabridge:    $(git -C "$ROOT/build/yabridge-src" rev-parse --short HEAD 2>/dev/null || echo '?')"
echo "  WINEPREFIX:  $WINEPREFIX  (COW clone of $REAL_PREFIX)"
echo "  VST_PATH:    $VST_PATH"
echo "  VST3_PATH:   $VST3_PATH"
echo "  CLAP_PATH:   $CLAP_PATH"
echo "  Original prefix is read-only-shared via COW — physically never modified."
echo "  Bridges resolve only inside the clone; production bridges are not used."
echo ""

exec "$DAW" "$@"
