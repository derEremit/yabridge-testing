#!/bin/bash
# daw-env.sh — Launch a DAW with pinned wine-staging + test yabridge against a
#              copy-on-write CLONE of your real Wine prefix.
#
# Isolated XLN installer 2026-08-29: success (Cotton 4.7.3, two restarts,
# "Everything is up to date") via wine-wait.sh + Program Files sync on
# the clone. Isolated Bitwig + AD2 2026-08-29 ~02:00: authorized on the
# same clone and pasta identity; WRONG COMPUTER ID closed for this path.
# Do not --fresh the clone. Procedure: docs/xln-isolated-installer.md
#
# Uses a reflink clone of your prefix; production paths are mounted read-only
# — not a guarantee.
#
# How it stays safe:
#   - Your real prefix (default: ~/.audio-production/winplugins) is reflink-
#     cloned into prefix-copy/. Reflink = btrfs copy-on-write: the clone shares
#     data extents with the original until something writes. Cloning only
#     READS the original.
#   - On the host, WINEPREFIX points at the clone so yabridgectl and Wine
#     upgrades never touch the production prefix. Inside Bubblewrap the clone
#     is bound over the resolved production prefix path and WINEPREFIX is
#     that path, so Bitwig keeps seeing the host paths it already indexed.
#     A ~/winplugins or ~/.vst symlink stays a symlink (bwrap cannot mount
#     onto one); the overlay lands on the directory it points at.
#   - Wine 11.8 will auto-upgrade the prefix on first run (registry + system
#     DLLs). That upgrade — and every plugin write — lands on COW extents in
#     prefix-copy/. The production prefix stays read-only on the host.
#   - Clone creation uses a temporary sibling and atomic rename. Failed copies
#     remove only that invocation's temporary clone.
#   - yabridge bridges are generated inside isolation/home, an isolated
#     HOME/XDG tree. yabridgectl add is called once per plugin directory so
#     paths with spaces stay one argument. Only the clone is registered, and
#     every generated Windows target must canonicalize inside prefix-copy/.
#     Your production yabridgectl configuration is never read or written.
#     Isolated ~/.vst/yabridge, ~/.vst3/yabridge and ~/.clap/yabridge are
#     bound over those same production path strings so Bitwig does not persist
#     isolation/home paths into ~/.BitwigStudio.
#   - The DAW runs inside Bubblewrap. The project tree and production plugin
#     roots (outside the yabridge overlay) are mounted READ-ONLY; only the
#     clone, the isolation tree, the real login home, and the paths you
#     approve with --writable-path are writable. The DAW's HOME is the real
#     login home so Bitwig opens ~/.BitwigStudio (not isolation/home, not
#     /root). Only the Wine prefix overlay, isolated yabridge plugin dirs,
#     and isolated XDG for yabridgectl stay isolated. The sandbox gets a
#     fresh network namespace unless you pass --network. If Bubblewrap or
#     the namespaces it needs are unavailable the launcher refuses to start
#     the DAW.
#   - Every run records what it actually is in run-state/run-manifest.json:
#     source and clone identity, Wine and yabridge versions, bridge roots, the
#     DAW, the sandbox boundary and the Wine diagnostics state. The manifest is
#     written after every check has passed and before the DAW starts. If it
#     cannot be written, the DAW does not run. It is kept outside every
#     writable tree, so the DAW it describes cannot rewrite its own record.
#
# The clone persists between runs (so the one-time wine upgrade isn't repeated
# and plugin state survives). Use --fresh to re-clone, --clean to delete it.
#
# Requirements:
#   - /home on btrfs (or any FS with reflink), or --copy for a full copy.
#   - ./setup.sh run at least once (builds yabridge, downloads wine 11.8).
#   - DAW installed natively (not flatpak/snap).
#   - bubblewrap 0.11+ and a kernel that permits its namespaces.
#
# Usage:
#   ./daw-env.sh reaper
#   ./daw-env.sh bitwig-studio
#   ./daw-env.sh reaper /path/to/project.rpp
#   ./daw-env.sh --fresh reaper            # re-clone the prefix first
#   ./daw-env.sh --refresh-bridges --mac "$XLN_MAC" --nic "$XLN_NIC" \
#       --writable-path "$(realpath -- "$BITWIG_PROJECTS")" bitwig-studio
#   ./daw-env.sh --prefix ~/.wine reaper   # clone a different real prefix
#   ./daw-env.sh --copy reaper             # if reflink fails, full-copy (maybe huge)
#   ./daw-env.sh --clean                   # delete prefix-copy/ + isolation/
#
# Plugin path options:
#   --native-plugin-path DIR   expose one existing, canonical, absolute native
#                              plugin directory to the DAW in addition to the
#                              isolated bridges. Repeatable. Nothing else is
#                              inherited. Rejected when it is the filesystem
#                              root, at or above your real home, at or above
#                              anything the sandbox creates for itself, or
#                              overlaps the production prefix, a production
#                              plugin root, the project tree, the clone or the
#                              isolation tree. A directory inside a read-only
#                              system root, such as /usr/lib/vst3, is fine.
#   --allow-empty              launch even when no bridges were generated.
#                              Fixtures and diagnostics only.
#
# Clone options:
#   --copy                     if reflink is unavailable, make a full copy
#                              of the source prefix. Prints the estimated
#                              size in GB first. Off by default: without
#                              this flag a missing reflink aborts.
#
# Sandbox options:
#   --writable-path DIR        make one existing, canonical, absolute directory
#                              writable inside the sandbox, for projects and
#                              rendered output. Repeatable. Rejected when it
#                              overlaps the production prefix, a production
#                              plugin root, a system root, the project tree,
#                              the clone or the isolation tree. The DAW's HOME
#                              is the real login home, so ~/.BitwigStudio and
#                              Wine known folders are already visible; naming
#                              a path under $HOME is optional. The production
#                              Wine prefix is never auto-bound writable.
#   --network                  give the DAW host network access. Off by
#                              default: the sandbox gets its own empty network
#                              namespace.
#   --mac MAC                  present one NIC with this MAC to Wine (XLN
#                              Computer ID). Implies shared networking.
#                              Creates a user+net namespace we own, starts
#                              pasta --config-net --mac-addr MAC from the
#                              host (attached with --userns/--netns) or
#                              slirp4netns, then runs real bwrap inside that
#                              netns (no --unshare-net). Pasta must start
#                              while host routes are still visible or it
#                              falls back to 169.254 local-mode. Firejail+
#                              nsenter is not used: Firejail's netns is not
#                              joinable unprivileged, firejail-as-parent
#                              replaces bwrap with fbwrap, and firejail
#                              inside bwrap drops --mac. Fails closed if
#                              pasta and slirp4netns are both missing
#                              (install passt).
#   --nic NAME                 host template for pasta --interface (default:
#                              the default-route interface, or $XLN_NIC). Wine still sees one NIC
#                              named eth0 (Firejail / xln-fj). --mac is the
#                              Computer ID. If the first argument is xln-fj,
#                              it is unwrapped and this identity is applied
#                              automatically.
#   --address ADDR             pin the pasta guest IPv4 Wine sees
#                              (pasta --address). Requires --mac. Daily
#                              xln-fj is a Firejail macvlan LAN address
#                              (the xln-fj LAN IP, see run-state/identity.env); pasta otherwise
#                              copies the host template (a NAT address).
#                              Still userspace NAT, not macvlan L2.
#
# Wine diagnostics options:
#   --quiet-wine               set WINEDEBUG=-all for the DAW. Off by default:
#                              Wine's own diagnostics are left exactly as your
#                              shell configured them, and nothing is invented
#                              when your shell configured nothing.

set -euo pipefail

SCRIPT_PATH="$(realpath -- "$0")"
ROOT="$(cd -P -- "$(dirname -- "$SCRIPT_PATH")" && pwd -P)"
COPY="$(realpath -m -- "$ROOT")/prefix-copy"
REAL_PREFIX="$HOME/.audio-production/winplugins"
FRESH=false
CLEAN=false
REFRESH_BRIDGES=false
ALLOW_EMPTY=false
ALLOW_FULL_COPY=false
NATIVE_PLUGIN_PATHS=()
REQUESTED_WRITABLE_PATHS=()
LAUNCH_COMMAND=()
EXEC_COMMAND=()

# Wine's own diagnostics belong to the caller, so what the calling shell asked
# for is captured before anything this project generates can overwrite it.
INHERITED_WINEDEBUG_SET=false
INHERITED_WINEDEBUG=""
if [[ -n "${WINEDEBUG+set}" ]]; then
    INHERITED_WINEDEBUG_SET=true
    INHERITED_WINEDEBUG="$WINEDEBUG"
fi

source "$ROOT/lib/component-state.sh"
source "$ROOT/lib/clone-state.sh"
source "$ROOT/lib/isolated-bridges.sh"
source "$ROOT/lib/sandbox.sh"
source "$ROOT/lib/run-manifest.sh"

# Host networking and quiet diagnostics must come from this command line and
# nowhere else, so exported values in the calling shell cannot quietly decide
# them. Reset after sourcing, before a single option is read.
SANDBOX_NETWORK=false
SANDBOX_MAC=""
SANDBOX_NIC=""
SANDBOX_ADDRESS=""
QUIET_WINE=false

daw_env_cleanup() {
    local status=$?
    trap - EXIT INT TERM
    stop_mac_netns_holder
    cleanup_owned_bridge_candidate
    cleanup_owned_bridge_scan_listing
    release_clone_lock
    return "$status"
}

# env.sh is a generated file in the project tree, sourced long after this
# command line has been parsed and every input validated. A copy left over from
# an older setup — or one somebody edited — must not be able to reach back and
# widen the boundary this invocation already settled, so each decision is
# captured before the file is read and reasserted afterwards. Anything the file
# tried to change is reported rather than silently reverted, because a
# generated environment that disagrees about policy is worth knowing about.
PROTECTED_POLICY_NAMES=(
    HOME SANDBOX_HOST_HOME SANDBOX_HOST_UID SANDBOX_HOST_GID SANDBOX_HOST_USER
    SANDBOX_NETWORK SANDBOX_MAC SANDBOX_NIC SANDBOX_ADDRESS QUIET_WINE
    SANDBOX_BWRAP
    SANDBOX_NAMESPACES_VERIFIED SANDBOX_UNSHARE_USER SANDBOX_DAW_PATH
    SANDBOX_UNSHARE SANDBOX_PASTA SANDBOX_SLIRP4NETNS SANDBOX_MAC_BACKEND
    SANDBOX_MAC_NETNS_EXEC SANDBOX_MAC_HOLDER_PID
    SANDBOX_PROJECT_ROOT SANDBOX_REAL_PREFIX SANDBOX_CLONE SANDBOX_ISOLATION
    RUN_STATE_DIR
)
declare -A PARSED_POLICY=()
PARSED_WRITABLE_PATHS=()
PARSED_NATIVE_PLUGIN_PATHS=()

capture_parsed_security_policy() {
    local name
    for name in "${PROTECTED_POLICY_NAMES[@]}"; do
        PARSED_POLICY["$name"]="${!name-}"
    done
    PARSED_WRITABLE_PATHS=(
        ${SANDBOX_WRITABLE_PATHS[@]+"${SANDBOX_WRITABLE_PATHS[@]}"})
    PARSED_NATIVE_PLUGIN_PATHS=(
        ${SANDBOX_NATIVE_PLUGIN_PATHS[@]+"${SANDBOX_NATIVE_PLUGIN_PATHS[@]}"})
}

report_policy_override() {
    echo "Warning: the generated environment $ROOT/env.sh changed $1;" \
        "this run uses what the command line decided." >&2
    echo "Regenerate it with ./setup.sh if this keeps happening." >&2
}

assert_parsed_security_policy() {
    local name

    for name in "${PROTECTED_POLICY_NAMES[@]}"; do
        [[ "${!name-}" == "${PARSED_POLICY[$name]}" ]] && continue
        report_policy_override "$name"
        printf -v "$name" '%s' "${PARSED_POLICY[$name]}"
    done
    if [[ "${SANDBOX_WRITABLE_PATHS[*]-}" != "${PARSED_WRITABLE_PATHS[*]-}" ]]; then
        report_policy_override "the approved writable paths"
        SANDBOX_WRITABLE_PATHS=(
            ${PARSED_WRITABLE_PATHS[@]+"${PARSED_WRITABLE_PATHS[@]}"})
    fi
    if [[ "${SANDBOX_NATIVE_PLUGIN_PATHS[*]-}" != \
        "${PARSED_NATIVE_PLUGIN_PATHS[*]-}" ]]; then
        report_policy_override "the native plugin paths"
        SANDBOX_NATIVE_PLUGIN_PATHS=(
            ${PARSED_NATIVE_PLUGIN_PATHS[@]+"${PARSED_NATIVE_PLUGIN_PATHS[@]}"})
    fi
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
        --copy) ALLOW_FULL_COPY=true; shift ;;
        --native-plugin-path)
            require_option_value "--native-plugin-path" "${2:-}"
            validate_native_plugin_path "$2" || exit 2
            NATIVE_PLUGIN_PATHS+=("$2")
            shift 2
            ;;
        --network) SANDBOX_NETWORK=true; shift ;;
        --mac)
            require_option_value "--mac" "${2:-}"
            validate_sandbox_mac "$2" || exit 2
            SANDBOX_MAC="$2"
            SANDBOX_NETWORK=true
            shift 2
            ;;
        --nic)
            require_option_value "--nic" "${2:-}"
            SANDBOX_NIC="$2"
            shift 2
            ;;
        --address)
            require_option_value "--address" "${2:-}"
            validate_sandbox_address "$2" || exit 2
            SANDBOX_ADDRESS="$2"
            shift 2
            ;;
        --quiet-wine) QUIET_WINE=true; shift ;;
        --writable-path)
            require_option_value "--writable-path" "${2:-}"
            REQUESTED_WRITABLE_PATHS+=("$2")
            shift 2
            ;;
        --clean)   CLEAN=true; shift ;;
        -h|--help)
            # The header block, printed to its own end rather than to a line
            # number, so documenting a new option cannot truncate the help.
            awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' \
                "$0"
            exit 0 ;;
        --) shift; break ;;
        -*) echo "Unknown option: $1" >&2; exit 1 ;;
        *)  break ;;
    esac
done

DAW="${1:-}"
if [[ "$CLEAN" != true && -z "$DAW" ]]; then
    echo "Usage: $0 [--fresh] [--refresh-bridges] [--allow-empty] [--copy] [--network]"
    echo "          [--mac MAC] [--nic NAME] [--address ADDR] [--quiet-wine] [--native-plugin-path DIR]..."
    echo "          [--writable-path DIR]... [--prefix DIR] <daw-binary> [args...]"
    echo "       $0 --clean"
    exit 1
fi
if [[ "$CLEAN" != true ]]; then
    shift 1
fi

# xln-fj as the "DAW" is the daily XLN identity wrapper. Nested inside
# Bubblewrap it silently drops --mac. Unwrap it here and apply the same
# identity outside bwrap. A raw firejail argv is refused: its flags would
# become the sandboxed program.
if [[ "$CLEAN" != true && -n "$DAW" ]]; then
    if sandbox_is_xln_identity_wrapper "$DAW"; then
        sandbox_apply_xln_wrapper_identity
        if [[ -z "${1:-}" || "${1:-}" == -* ]]; then
            echo "Error: $DAW requires the real DAW as the next argument" >&2
            echo "Example: $0 --network $DAW bitwig-studio" >&2
            exit 2
        fi
        DAW="$1"
        shift 1
    elif [[ "$(basename -- "$DAW")" == firejail ]]; then
        echo "Error: do not launch firejail inside the sandbox." >&2
        echo "Pass --mac and --nic, or use xln-fj as the first argument" \
            "(it is unwrapped and applied outside Bubblewrap)." >&2
        exit 2
    fi
    if [[ -n "$SANDBOX_MAC" && -z "$SANDBOX_NIC" ]]; then
        # Best-effort host template for pasta --interface. Wine-facing name is eth0.
        default_nic="${XLN_NIC:-$SANDBOX_DEFAULT_NIC}"
        if [[ -e "${SANDBOX_NIC_SYSFS:-/sys/class/net}/$default_nic" ]]; then
            SANDBOX_NIC="$default_nic"
        fi
    fi
    if [[ -n "$SANDBOX_NIC" && -z "$SANDBOX_MAC" ]]; then
        echo "Error: --nic requires --mac or an xln-fj wrapper" >&2
        exit 2
    fi
    if [[ -n "$SANDBOX_ADDRESS" && -z "$SANDBOX_MAC" ]]; then
        echo "Error: --address requires --mac so pasta can pin the guest IPv4" >&2
        exit 2
    fi
    if [[ -n "$SANDBOX_MAC" ]]; then
        validate_sandbox_mac "$SANDBOX_MAC" || exit 2
        if [[ -n "$SANDBOX_NIC" ]]; then
            validate_sandbox_nic "$SANDBOX_NIC" || exit 2
        fi
        if [[ -n "$SANDBOX_ADDRESS" ]]; then
            validate_sandbox_address "$SANDBOX_ADDRESS" || exit 2
        fi
    fi
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
# The run manifest describes a run to whoever reads it afterwards, so it is
# deliberately not kept in the isolation tree the sandbox makes writable. It
# lives in its own generated directory directly under the project root, which
# the sandbox binds read-only in full — the DAW this record describes can read
# it and cannot change it.
RUN_STATE_DIR="$ROOT/run-state"
# Named here rather than just before the command is built, because what these
# directories are decides whether the boundary can be enforced at all — and a
# refusal has to come before the clone, the bridge sync and the plugin paths
# handed to the DAW.
SANDBOX_NATIVE_PLUGIN_PATHS=(${NATIVE_PLUGIN_PATHS[@]+"${NATIVE_PLUGIN_PATHS[@]}"})
COMPONENT_STATE_FILE="$ROOT/build/component-state.env"
if [[ "$CLEAN" != true ]]; then
    resolve_daw_executable "$DAW" || exit 1
    require_bwrap || exit 1
    if [[ -n "$SANDBOX_MAC" ]]; then
        require_unshare || exit 1
        require_mac_netns_backend || exit 1
    fi
    assert_sandbox_namespaces || exit 1
    assert_sandbox_inputs || exit 1
    # Both are knowable now: the generated environment names every component
    # this run uses, and the component state says which ones setup installed.
    # Asking here means a project that was never set up is refused before it
    # costs a clone and a bridge sync.
    if [[ ! -f "$ROOT/env.sh" ]]; then
        echo "Error: the generated environment is missing: $ROOT/env.sh" >&2
        echo "Run ./setup.sh to generate it." >&2
        exit 1
    fi
    assert_recorded_components "$COMPONENT_STATE_FILE" || exit 1
    for requested in ${REQUESTED_WRITABLE_PATHS[@]+"${REQUESTED_WRITABLE_PATHS[@]}"}; do
        validate_writable_path "$requested" || exit 2
        SANDBOX_WRITABLE_PATHS+=("$requested")
    done
    # Snapshot the login identity before yabridge generation or env.sh can
    # change HOME. The DAW keeps this HOME; isolation/home is only for
    # yabridge and XDG.
    sandbox_snapshot_host_identity || exit 2
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
    clone_prefix_atomic "$REAL_PREFIX" "$COPY" "$clone_exists" "$ALLOW_FULL_COPY"
fi

# ── Build the environment ────────────────────────────────────────────────────
# env.sh sets WINELOADER/WINESERVER/WINEDLLPATH/PATH/LD_LIBRARY_PATH (wine 11.8
# + test yabridge) and also WINEPREFIX=prefix/ — we override that below.
capture_parsed_security_policy
# env.sh is generated by setup and is not present at lint time.
# shellcheck source=/dev/null
source "$ROOT/env.sh"
assert_parsed_security_policy
export WINEPREFIX="$COPY"

# ── Resolve the components this run will use and record ──────────────────────
# env.sh names absolute paths, but a project kept behind a symlink or a Wine
# build reached through a linked directory still names usable executables. Each
# one is resolved once, here, so the bridges, the launch and the manifest all
# refer to the same object — and so a usable component is never refused later
# for the name it was given rather than for what it is.
WINE_EXECUTABLE="$(resolve_component_executable "the Wine executable" \
    "${WINELOADER:-}")" || exit 1
export WINELOADER="$WINE_EXECUTABLE"
if [[ -n "${WINESERVER:-}" ]]; then
    SANDBOX_WINESERVER="$(resolve_component_executable "the wineserver executable" \
        "$WINESERVER")" || SANDBOX_WINESERVER="$WINESERVER"
    export WINESERVER="$SANDBOX_WINESERVER"
fi

# ── Wine diagnostics ─────────────────────────────────────────────────────────
# Only --quiet-wine silences Wine. Otherwise the value the calling shell set is
# restored exactly as it was given, and when it set nothing the variable is left
# unset rather than being invented here — including when an env.sh generated
# before this rule silenced it.
if [[ "$QUIET_WINE" == true ]]; then
    export WINEDEBUG=-all
elif [[ "$INHERITED_WINEDEBUG_SET" == true ]]; then
    export WINEDEBUG="$INHERITED_WINEDEBUG"
else
    unset WINEDEBUG
fi

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

# Re-proved now that the clone is the prefix this run will actually use. A
# status of 2 means the directory is simply not there, which the earlier call
# reads as "nothing has been cloned yet" — by this point it means the clone
# vanished after it was made, and saying so beats exiting with a bare 2.
if ! validate_clone_provenance "$COPY" "$REAL_PREFIX"; then
    clone_status=$?
    if [[ "$clone_status" -eq 2 ]]; then
        echo "Error: the prefix clone disappeared after it was created: $COPY" >&2
        echo "Something removed it while this launch was preparing." >&2
    fi
    exit 1
fi

# ── Generate bridges that can only reach the clone ────────────────────────────
# clone_prefix_atomic clears its own traps on success, so the composed cleanup
# is reinstalled here to cover both the clone lock and the bridge candidate.
trap daw_env_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

YABRIDGE_HOME="$(resolve_component_directory "the yabridge home" \
    "${YABRIDGE_BIN:-$ROOT/build/yabridge}")" || exit 1
YABRIDGECTL="$YABRIDGE_HOME/yabridgectl"
if [[ ! -x "$YABRIDGECTL" ]] && ! YABRIDGECTL="$(command -v yabridgectl)"; then
    echo "Error: yabridgectl not found in $YABRIDGE_HOME or PATH" >&2
    echo "Run ./setup.sh to build it, or install yabridgectl." >&2
    exit 1
fi
# A packaged yabridgectl is usually a symlink into a versioned directory, so
# what is recorded is the executable that link leads to.
YABRIDGECTL="$(resolve_component_executable "the yabridgectl executable" \
    "$YABRIDGECTL")" || exit 1

# Both are read by lib/isolated-bridges.sh.
# shellcheck disable=SC2034
ISOLATED_BRIDGES_REFRESH="$REFRESH_BRIDGES"
# shellcheck disable=SC2034
ISOLATED_BRIDGES_ALLOW_EMPTY="$ALLOW_EMPTY"
prepare_isolated_bridges "$ROOT" "$COPY" "$YABRIDGECTL" "$YABRIDGE_HOME"
export_isolated_plugin_paths ${NATIVE_PLUGIN_PATHS[@]+"${NATIVE_PLUGIN_PATHS[@]}"}
# XLN's updater remove_all's the updateBinary exe while it is the running
# image (Wine Access denied / 5). When Program Files on the clone already
# matches updateBinary, launch that exe (launchCopy is a bootstrapper that
# ReplaceFileW's, ShellExecute's Program Files, and exits; --die-with-parent
# then kills the child). Otherwise stage launchCopy. The cacert --ro-bind
# is each CAfile only; it does not lock the exe.
if [[ $# -gt 0 ]]; then
    set -- "${@:1:$(($#-1))}" \
        "$(sandbox_xln_updatebinary_launch_arg "$COPY" "${@: -1}")"
fi
# ReplaceFileW cannot install the new exe into Program Files. After a
# self-update quit, sync that clone-only path from updateBinary so the
# next session does not immediately update and exit again.
sandbox_sync_xln_program_files_from_updatebinary "$COPY" || true
# XLN installer curl CAfile is deleted by ReplaceFileW on every start.
sandbox_pin_xln_installer_cacert "$COPY" || true

# ── Build the sandbox command ────────────────────────────────────────────────
# The command is an argv array, so every DAW argument reaches the DAW exactly
# as it was given. The canonical executable from the preflight is passed rather
# than the name, so sourcing env.sh cannot have changed which binary this is.
SANDBOX_ISOLATED_HOME="$ISOLATED_BRIDGE_HOME"
build_bwrap_command LAUNCH_COMMAND "$SANDBOX_DAW_PATH" "$@" || exit 1

# ── Record what this run actually is ─────────────────────────────────────────
# Written after the clone, the bridges and the finished sandbox command have all
# been validated, and before the DAW can change any of it. Every identity is
# proven again while the manifest is written, and the sandbox command itself is
# checked against the boundary the manifest claims, so a run that cannot be
# described accurately is a run that does not start.
RUN_MANIFEST_SOURCE="$REAL_PREFIX"
RUN_MANIFEST_CLONE="$COPY"
RUN_MANIFEST_CLONE_IDENTITY="$VALIDATED_CLONE_IDENTITY"
RUN_MANIFEST_STATE_FILE="$COMPONENT_STATE_FILE"
RUN_MANIFEST_WINE_EXECUTABLE="$WINE_EXECUTABLE"
RUN_MANIFEST_YABRIDGE_HOME="$YABRIDGE_HOME"
RUN_MANIFEST_YABRIDGECTL="$YABRIDGECTL"
RUN_MANIFEST_BRIDGE_HOME="$ISOLATED_BRIDGE_HOME"
RUN_MANIFEST_DAW="$SANDBOX_DAW_PATH"
RUN_MANIFEST_BWRAP="$SANDBOX_BWRAP"
RUN_MANIFEST_NAMESPACES_VERIFIED="$SANDBOX_NAMESPACES_VERIFIED"
RUN_MANIFEST_UNSHARE_USER="$SANDBOX_UNSHARE_USER"
RUN_MANIFEST_NETWORK="$SANDBOX_NETWORK"
RUN_MANIFEST_QUIET_WINE="$QUIET_WINE"
if [[ -n "${WINEDEBUG+set}" ]]; then
    RUN_MANIFEST_WINEDEBUG_SET=true
    RUN_MANIFEST_WINEDEBUG="$WINEDEBUG"
else
    RUN_MANIFEST_WINEDEBUG_SET=false
    RUN_MANIFEST_WINEDEBUG=""
fi
RUN_MANIFEST_FILE="$RUN_STATE_DIR/$RUN_MANIFEST_NAME"
if ! mkdir -p -- "$RUN_STATE_DIR"; then
    echo "Error: could not create the run state directory: $RUN_STATE_DIR" >&2
    exit 1
fi
write_run_manifest "$RUN_MANIFEST_FILE" LAUNCH_COMMAND || exit 1

# Manifest records the bwrap argv. MAC identity is unshare user+net + pasta
# started from the host and attached to that netns (or slirp4netns), then
# real bwrap inside it — never firejail wrapping bwrap (fbwrap), never
# firejail inside bwrap (--mac dropped), never nsenter into Firejail.
EXEC_COMMAND=("${LAUNCH_COMMAND[@]}")
if [[ -n "$SANDBOX_MAC" ]]; then
    EXEC_COMMAND=()
    wrap_launch_with_mac_identity EXEC_COMMAND LAUNCH_COMMAND || exit 1
fi

# ── Launch ───────────────────────────────────────────────────────────────────
if [[ -n "$SANDBOX_MAC" ]]; then
    network_status="unshare user+net + $SANDBOX_MAC_BACKEND --mac-addr $SANDBOX_MAC"
    if [[ -n "$SANDBOX_ADDRESS" ]]; then
        network_status+=" --address $SANDBOX_ADDRESS"
    fi
    network_status+=" (bwrap inherits; --nic is Firejail-era alias)"
elif [[ "$SANDBOX_NETWORK" == true ]]; then
    network_status="host network (--network)"
else
    network_status="isolated (no network namespace access)"
fi
echo ""
echo "Launching $DAW with:"
echo "  WINELOADER:  $WINELOADER ($(wine --version 2>/dev/null || echo '?'))"
echo "  yabridge:    $(git -C "$ROOT/build/yabridge-src" rev-parse --short HEAD 2>/dev/null || echo '?')"
echo "  WINEPREFIX:  $REAL_PREFIX  (clone $COPY overlaid at production path)"
echo "  VST_PATH:    $VST_PATH"
echo "  VST3_PATH:   $VST3_PATH"
echo "  CLAP_PATH:   $CLAP_PATH"
echo "  sandbox:     $SANDBOX_BWRAP (user namespace: $SANDBOX_UNSHARE_USER)"
echo "  network:     $network_status"
echo "  WINEDEBUG:   ${WINEDEBUG-<unset>}$([[ "$QUIET_WINE" == true ]] &&
    echo ' (--quiet-wine)')"
echo "  manifest:    $RUN_MANIFEST_FILE"
echo "  writable:    $COPY, $SANDBOX_ISOLATION${SANDBOX_WRITABLE_PATHS[*]+, ${SANDBOX_WRITABLE_PATHS[*]}}"
echo "  Production prefix and plugin roots are mounted read-only."
echo "  Bridges resolve only inside the clone; production bridges are not used."
echo ""

# The clone lock is held through the manifest write and released here.
# MAC identity starts pasta/slirp from the host attached to the helper
# netns, which reaps it when bwrap exits. This path exec-replaces like
# any other launch.
release_clone_lock
trap - EXIT INT TERM

exec "${EXEC_COMMAND[@]}"
