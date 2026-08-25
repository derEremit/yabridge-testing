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
#   - The DAW runs inside Bubblewrap. Your real prefix, your production plugin
#     roots and the project tree are mounted READ-ONLY; only the clone, the
#     isolation tree and the paths you approve with --writable-path are
#     writable. The sandbox gets a fresh network namespace unless you pass
#     --network. If Bubblewrap or the namespaces it needs are unavailable the
#     launcher refuses to start the DAW.
#
# The clone persists between runs (so the one-time wine upgrade isn't repeated
# and plugin state survives). Use --fresh to re-clone, --clean to delete it.
#
# Requirements:
#   - /home on btrfs (or any FS with reflink). Verified: yes.
#   - ./setup.sh run at least once (builds yabridge, downloads wine 11.8).
#   - DAW installed natively (not flatpak/snap).
#   - bubblewrap 0.11+ and a kernel that permits its namespaces.
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
#
# Sandbox options:
#   --writable-path DIR        make one existing, canonical, absolute directory
#                              writable inside the sandbox, for projects and
#                              rendered output. Repeatable. Rejected when it
#                              overlaps the production prefix, a production
#                              plugin root, a system root, the project tree,
#                              the clone or the isolation tree.
#   --network                  give the DAW host network access. Off by
#                              default: the sandbox gets its own empty network
#                              namespace.

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
REQUESTED_WRITABLE_PATHS=()
LAUNCH_COMMAND=()

source "$ROOT/lib/clone-state.sh"
source "$ROOT/lib/isolated-bridges.sh"
source "$ROOT/lib/sandbox.sh"

# Host networking must come from --network on this command line and nowhere
# else, so an exported SANDBOX_NETWORK in the calling shell cannot quietly
# decide it. Reset after sourcing, before a single option is read.
SANDBOX_NETWORK=false

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
        --network) SANDBOX_NETWORK=true; shift ;;
        --writable-path)
            require_option_value "--writable-path" "${2:-}"
            REQUESTED_WRITABLE_PATHS+=("$2")
            shift 2
            ;;
        --clean)   CLEAN=true; shift ;;
        -h|--help)
            sed -n '2,66p' "$0" | sed 's/^# \?//'
            exit 0 ;;
        --) shift; break ;;
        -*) echo "Unknown option: $1" >&2; exit 1 ;;
        *)  break ;;
    esac
done
export YABRIDGE_STAGING_REFRESH_BRIDGES="$REFRESH_BRIDGES"

DAW="${1:-}"
if [[ "$CLEAN" != true && -z "$DAW" ]]; then
    echo "Usage: $0 [--fresh] [--refresh-bridges] [--allow-empty] [--network]"
    echo "          [--native-plugin-path DIR]... [--writable-path DIR]..."
    echo "          [--prefix DIR] <daw-binary> [args...]"
    echo "       $0 --clean"
    exit 1
fi
if [[ "$CLEAN" != true ]]; then
    shift 1
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

# ── Prove the sandbox boundary before touching or generating anything ────────
# The DAW is resolved, Bubblewrap is required, its namespaces are probed and
# every sandbox input is validated before the prefix is cloned and before
# yabridgectl runs. A host that cannot enforce the boundary, and an input the
# boundary would have to refuse, therefore never reaches a DAW, a clone, a
# clone candidate or a bridge sync.
SANDBOX_PROJECT_ROOT="$ROOT"
SANDBOX_REAL_PREFIX="$REAL_PREFIX"
SANDBOX_CLONE="$COPY"
SANDBOX_ISOLATION="$ROOT/isolation"
if [[ "$CLEAN" != true ]]; then
    resolve_daw_executable "$DAW" || exit 1
    require_bwrap || exit 1
    assert_sandbox_namespaces || exit 1
    assert_sandbox_inputs || exit 1
    for requested in ${REQUESTED_WRITABLE_PATHS[@]+"${REQUESTED_WRITABLE_PATHS[@]}"}; do
        validate_writable_path "$requested" || exit 2
        SANDBOX_WRITABLE_PATHS+=("$requested")
    done
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

# Both are read by lib/isolated-bridges.sh.
# shellcheck disable=SC2034
ISOLATED_BRIDGES_REFRESH="$REFRESH_BRIDGES"
# shellcheck disable=SC2034
ISOLATED_BRIDGES_ALLOW_EMPTY="$ALLOW_EMPTY"
prepare_isolated_bridges "$ROOT" "$COPY" "$YABRIDGECTL" "$YABRIDGE_HOME"
export_isolated_plugin_paths ${NATIVE_PLUGIN_PATHS[@]+"${NATIVE_PLUGIN_PATHS[@]}"}

release_clone_lock
trap - EXIT INT TERM

# ── Build the sandbox command ────────────────────────────────────────────────
# The command is an argv array, so every DAW argument reaches the DAW exactly
# as it was given. The canonical executable from the preflight is passed rather
# than the name, so sourcing env.sh cannot have changed which binary this is.
SANDBOX_ISOLATED_HOME="$ISOLATED_BRIDGE_HOME"
SANDBOX_NATIVE_PLUGIN_PATHS=(${NATIVE_PLUGIN_PATHS[@]+"${NATIVE_PLUGIN_PATHS[@]}"})
build_bwrap_command LAUNCH_COMMAND "$SANDBOX_DAW_PATH" "$@" || exit 1

# ── Launch ───────────────────────────────────────────────────────────────────
if [[ "$SANDBOX_NETWORK" == true ]]; then
    network_status="host network (--network)"
else
    network_status="isolated (no network namespace access)"
fi
echo ""
echo "Launching $DAW with:"
echo "  WINELOADER:  $WINELOADER ($(wine --version 2>/dev/null || echo '?'))"
echo "  yabridge:    $(git -C "$ROOT/build/yabridge-src" rev-parse --short HEAD 2>/dev/null || echo '?')"
echo "  WINEPREFIX:  $WINEPREFIX  (COW clone of $REAL_PREFIX)"
echo "  VST_PATH:    $VST_PATH"
echo "  VST3_PATH:   $VST3_PATH"
echo "  CLAP_PATH:   $CLAP_PATH"
echo "  sandbox:     $SANDBOX_BWRAP (user namespace: $SANDBOX_UNSHARE_USER)"
echo "  network:     $network_status"
echo "  writable:    $COPY, $SANDBOX_ISOLATION${SANDBOX_WRITABLE_PATHS[*]+, ${SANDBOX_WRITABLE_PATHS[*]}}"
echo "  Production prefix and plugin roots are mounted read-only."
echo "  Bridges resolve only inside the clone; production bridges are not used."
echo ""

exec "${LAUNCH_COMMAND[@]}"
