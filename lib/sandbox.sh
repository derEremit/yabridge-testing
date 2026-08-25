#!/bin/bash
# lib/sandbox.sh — build a fail-closed Bubblewrap command for an isolated DAW.
#
# The result is always an argv *array*, never a string that a shell has to
# re-parse, so a DAW argument may contain spaces, globs, quotes or leading
# dashes without changing what is executed.
#
# The boundary this file constructs:
#   - production Wine prefix and production plugin roots: read-only;
#   - the project tree (wine 11.8, test yabridge, env.sh): read-only;
#   - the validated clone and this invocation's isolation tree: writable;
#   - an isolated tmpfs runtime directory plus only the display and audio
#     sockets that actually exist: nothing else of the real home;
#   - a new network namespace unless host networking was explicitly requested.
#
# Bubblewrap applies operations in the order they appear, so a broad mount may
# only ever be followed by narrower ones. Every destination is registered as it
# is planned, and a duplicate or shadowing destination fails closed instead of
# silently replacing an earlier decision.

# Inputs the launcher fills in before a command is built.
SANDBOX_PROJECT_ROOT="${SANDBOX_PROJECT_ROOT:-}"
SANDBOX_REAL_PREFIX="${SANDBOX_REAL_PREFIX:-}"
SANDBOX_CLONE="${SANDBOX_CLONE:-}"
SANDBOX_ISOLATION="${SANDBOX_ISOLATION:-}"
SANDBOX_ISOLATED_HOME="${SANDBOX_ISOLATED_HOME:-}"
# Never seeded from the environment: host networking is a decision the caller
# makes explicitly, so sourcing this file always starts from the closed state.
SANDBOX_NETWORK=false
SANDBOX_WRITABLE_PATHS=()
SANDBOX_NATIVE_PLUGIN_PATHS=()

# Resolved state.
SANDBOX_BWRAP=""
SANDBOX_DAW_PATH=""
SANDBOX_NAMESPACES_VERIFIED=false
SANDBOX_UNSHARE_USER=false

# Host layout. This is configuration rather than user input; fixtures override
# it so command construction is deterministic on any machine.
SANDBOX_SYSTEM_ROOTS=(/usr /etc /opt /sys)
SANDBOX_USR_MERGE_LINKS=(/bin /sbin /lib /lib32 /lib64 /libx32)
SANDBOX_DEVICE_PATHS=(/dev/snd /dev/dri)
SANDBOX_RUNTIME_SOCKETS=(pulse/native pipewire-0)
SANDBOX_X11_SOCKET_DIR="/tmp/.X11-unix"
SANDBOX_X11_DESTINATION_DIR="/tmp/.X11-unix"
SANDBOX_PLUGIN_ROOT_NAMES=(.vst .vst3 .clap)
SANDBOX_PROBE_COMMANDS=(/usr/bin/true /bin/true)

# Nothing may ever become writable at, above, or below one of these trees.
SANDBOX_PROTECTED_SYSTEM_TREES=(
    /usr /etc /bin /sbin /lib /lib32 /lib64 /libx32
    /opt /boot /dev /proc /run /sys /var
)

# Mount plan, rebuilt for every command.
SANDBOX_MOUNT_ARGUMENTS=()
SANDBOX_MOUNT_DESTINATIONS=()
SANDBOX_MOUNT_PASSTHROUGH=()

sandbox_error() {
    echo "Error: $*" >&2
}

sandbox_path_within() {
    local path="$1"
    local root="$2"

    [[ "$root" == / ]] && return 0
    [[ "$path" == "$root" || "$path" == "$root"/* ]]
}

# Rejects the shapes that turn a path into something other than a path: an
# option token, a value that breaks a `:`-separated list, an embedded newline,
# or a relative path whose meaning depends on the caller's directory.
sandbox_assert_plain_path() {
    local label="$1"
    local value="${2:-}"

    if [[ -z "$value" ]]; then
        sandbox_error "$label requires a value"
        return 1
    fi
    if [[ "$value" == -* ]]; then
        sandbox_error "$label must not look like an option: $value"
        return 1
    fi
    if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
        sandbox_error "$label must not contain newlines"
        return 1
    fi
    if [[ "$value" == *:* ]]; then
        sandbox_error "$label must not contain ':': $value"
        return 1
    fi
    if [[ "$value" != /* ]]; then
        sandbox_error "$label must be an absolute path: $value"
        return 1
    fi
}

# The state that must never become writable, whether or not it exists yet.
# Plugin roots are protected by name, so creating ~/.vst later cannot widen
# what an already accepted option means. `/` is deliberately absent: it is
# rejected as an ancestor of the system trees instead of matching everything.
#
# Every protected tree is also emitted under its canonical name. A production
# plugin root is frequently a symlink to storage elsewhere, and a lexical check
# alone would accept that storage under its real name — handing the caller a
# writable bind onto production bridges.
sandbox_protected_trees() {
    local tree name

    for tree in "${SANDBOX_PROTECTED_SYSTEM_TREES[@]}"; do
        printf '%s\n' "$tree"
    done
    for name in "${SANDBOX_PLUGIN_ROOT_NAMES[@]}"; do
        printf '%s\n' "$HOME/$name"
        sandbox_canonical_alias "$HOME/$name"
    done
    for tree in "$SANDBOX_REAL_PREFIX" "$SANDBOX_PROJECT_ROOT" \
        "$SANDBOX_CLONE" "$SANDBOX_ISOLATION"; do
        [[ -n "$tree" ]] || continue
        printf '%s\n' "$tree"
        sandbox_canonical_alias "$tree"
    done
}

# The canonical name of a path, printed only when it differs from the path
# itself. Silent when the path does not exist: the lexical name stays protected
# either way, and an unresolvable production plugin root is refused when the
# command is built rather than here.
sandbox_canonical_alias() {
    local path="$1"
    local canonical

    canonical="$(realpath -e -- "$path" 2>/dev/null)" || return 0
    [[ "$canonical" != "$path" ]] && printf '%s\n' "$canonical"
    return 0
}

validate_writable_path() {
    local value="${1:-}"
    local canonical existing tree

    sandbox_assert_plain_path "--writable-path" "$value" || return 1
    if ! canonical="$(realpath -e -- "$value" 2>/dev/null)"; then
        sandbox_error "--writable-path does not exist: $value"
        return 1
    fi
    if [[ "$canonical" != "$value" ]]; then
        sandbox_error "--writable-path must be a canonical path without symlinks: $value -> $canonical"
        return 1
    fi
    if [[ ! -d "$canonical" ]]; then
        sandbox_error "--writable-path is not a directory: $canonical"
        return 1
    fi

    while IFS= read -r tree; do
        if sandbox_path_within "$canonical" "$tree" ||
            sandbox_path_within "$tree" "$canonical"; then
            sandbox_error "--writable-path overlaps protected state ($tree): $canonical"
            return 1
        fi
    done < <(sandbox_protected_trees)

    for existing in ${SANDBOX_WRITABLE_PATHS[@]+"${SANDBOX_WRITABLE_PATHS[@]}"}; do
        if [[ "$existing" == "$canonical" ]]; then
            sandbox_error "--writable-path was already given: $canonical"
            return 1
        fi
    done
}

# Resolved before any mount is planned: the DAW's own location decides which
# install root has to be exposed read-only.
resolve_daw_executable() {
    local name="${1:-}"
    local resolved canonical

    if [[ -z "$name" ]]; then
        sandbox_error "no DAW executable was given"
        return 1
    fi
    if [[ "$name" == */* ]]; then
        resolved="$name"
    elif ! resolved="$(command -v -- "$name" 2>/dev/null)" ||
        [[ "$resolved" != /* ]]; then
        sandbox_error "'$name' was not found in PATH as an executable file"
        return 1
    fi
    if ! canonical="$(realpath -e -- "$resolved" 2>/dev/null)"; then
        sandbox_error "the DAW executable does not resolve: $resolved"
        return 1
    fi
    if [[ ! -f "$canonical" || ! -x "$canonical" ]]; then
        sandbox_error "the DAW is not an executable file: $canonical"
        return 1
    fi
    if [[ "$canonical" == *$'\n'* || "$canonical" == *$'\r'* ]]; then
        sandbox_error "the DAW path contains an unsupported newline"
        return 1
    fi
    SANDBOX_DAW_PATH="$canonical"
}

# The directory a production plugin root points at, or nothing when there is no
# plugin root to expose. An alias that cannot be proven safe is refused rather
# than skipped: bridges the launcher cannot see are bridges it cannot promise
# are read-only, and answering an alias with a home-wide bind would defeat the
# boundary it is trying to enforce.
sandbox_plugin_root_target() {
    local root="$1"
    local canonical

    if [[ ! -L "$root" ]]; then
        # A plain file named .vst cannot hold bridges, so there is nothing to
        # expose and nothing to refuse.
        [[ -d "$root" ]] && printf '%s\n' "$root"
        return 0
    fi
    if ! canonical="$(realpath -e -- "$root" 2>/dev/null)"; then
        sandbox_error "the production plugin root $root is a symlink that does not resolve"
        return 1
    fi
    if [[ ! -d "$canonical" ]]; then
        sandbox_error "the production plugin root $root does not resolve to a directory: $canonical"
        return 1
    fi
    if [[ "$canonical" == *$'\n'* || "$canonical" == *$'\r'* ]]; then
        sandbox_error "the production plugin root $root resolves to a path containing a newline"
        return 1
    fi
    if [[ "$canonical" == / ]] || sandbox_path_within "$HOME" "$canonical"; then
        sandbox_error "the production plugin root $root resolves to the real home ($canonical); refusing a home-wide bind"
        return 1
    fi
    printf '%s\n' "$canonical"
}

# The directory a DAW has to see to start. A self-contained installation keeps
# its libraries and resources next to `bin`, so a `bin` directory is widened to
# its parent — but never far enough to expose the real home or the whole
# filesystem, which are exactly the shortcuts this launcher refuses to take.
sandbox_daw_install_root() {
    local executable="$1"
    local directory parent root

    directory="$(dirname -- "$executable")"
    root="$directory"
    # Inside the real home there is no widening at all: the parent of a `bin`
    # directory there is a home subtree such as ~/.local, which holds far more
    # than the DAW. Only installations outside the home are widened.
    if [[ "$(basename -- "$directory")" == bin ]] &&
        ! sandbox_path_within "$directory" "$HOME"; then
        parent="$(dirname -- "$directory")"
        if [[ "$parent" != / ]] && ! sandbox_path_within "$HOME" "$parent"; then
            root="$parent"
        fi
    fi
    if [[ "$root" == / ]]; then
        sandbox_error "the DAW install root would be the whole filesystem: $executable"
        return 1
    fi
    if sandbox_path_within "$HOME" "$root"; then
        sandbox_error "the DAW install root would expose the real home ($root): $executable"
        echo "Install the DAW in its own directory instead of directly in \$HOME." >&2
        return 1
    fi
    printf '%s\n' "$root"
}

sandbox_require_resolved_daw() {
    if [[ -z "$SANDBOX_DAW_PATH" ]]; then
        sandbox_error "the DAW was not resolved by the preflight; refusing to plan a sandbox"
        return 1
    fi
}

# The inputs that decide what the sandbox will expose, checked while refusing
# is still free. Every check here is repeated where it is enforced, as the
# command is built; the point of this pass is only to move a refusal in front
# of the clone and the bridge sync, so a rejected input costs the user nothing
# and leaves no state behind.
assert_sandbox_inputs() {
    local name root

    sandbox_require_resolved_daw || return 1
    sandbox_daw_install_root "$SANDBOX_DAW_PATH" > /dev/null || return 1
    for name in "${SANDBOX_PLUGIN_ROOT_NAMES[@]}"; do
        root="$HOME/$name"
        [[ -e "$root" || -L "$root" ]] || continue
        sandbox_plugin_root_target "$root" > /dev/null || return 1
    done
}

# Confirms a command is being built for the executable the preflight already
# validated. Re-resolving keeps the fail-closed file checks against a binary
# replaced in the meantime, and a name that now resolves somewhere else is
# refused rather than launched — the sandbox was planned around the first
# answer, so a second one is a different program.
sandbox_confirm_daw_executable() {
    local requested="$1"
    local expected="$SANDBOX_DAW_PATH"

    resolve_daw_executable "$requested" || return 1
    if [[ -n "$expected" && "$SANDBOX_DAW_PATH" != "$expected" ]]; then
        sandbox_error "the DAW no longer resolves to the executable the preflight accepted: $expected -> $SANDBOX_DAW_PATH"
        SANDBOX_DAW_PATH="$expected"
        return 1
    fi
}

require_bwrap() {
    local resolved canonical

    if ! resolved="$(command -v -- bwrap 2>/dev/null)" ||
        [[ "$resolved" != /* ]]; then
        sandbox_error "bwrap was not found in PATH"
        echo "Isolated DAW runs require bubblewrap 0.11 or newer." >&2
        echo "Install it (Arch: pacman -S bubblewrap) and try again." >&2
        return 1
    fi
    if ! canonical="$(realpath -e -- "$resolved" 2>/dev/null)" ||
        [[ ! -x "$canonical" ]]; then
        sandbox_error "bwrap is not an executable file: $resolved"
        return 1
    fi
    SANDBOX_BWRAP="$canonical"
}

sandbox_probe_command() {
    local candidate

    for candidate in "${SANDBOX_PROBE_COMMANDS[@]}"; do
        if [[ -x "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    sandbox_error "no probe command is available to test sandbox support"
    return 1
}

sandbox_namespace_flags() {
    local -n __sandbox_flags="$1"
    local unshare_user="$2"
    local network="$3"

    __sandbox_flags+=(--unshare-pid --unshare-ipc --unshare-uts)
    # Cgroup namespaces are missing on older kernels; every other namespace is
    # mandatory, so this is the only one allowed to degrade.
    __sandbox_flags+=(--unshare-cgroup-try)
    [[ "$unshare_user" == true ]] && __sandbox_flags+=(--unshare-user)
    [[ "$network" == true ]] || __sandbox_flags+=(--unshare-net)
    __sandbox_flags+=(--die-with-parent --new-session)
    return 0
}

# The system view every sandbox needs, shared by the capability probe and the
# real launch so the probe proves what the launch will do. Merged-/usr layouts
# keep /lib64 and friends as symlinks; recreating them as symlinks instead of
# binding their targets is what lets a dynamic loader path resolve inside.
sandbox_append_system_view() {
    local -n __sandbox_view="$1"
    local register="$2"
    local root link target

    for root in "${SANDBOX_SYSTEM_ROOTS[@]}"; do
        [[ -d "$root" && ! -L "$root" ]] || continue
        __sandbox_view+=(--ro-bind "$root" "$root")
        if [[ "$register" == true ]]; then
            SANDBOX_MOUNT_DESTINATIONS+=("$root")
            SANDBOX_MOUNT_PASSTHROUGH+=("$root")
        fi
    done
    for link in "${SANDBOX_USR_MERGE_LINKS[@]}"; do
        if [[ -L "$link" ]]; then
            target="$(readlink -- "$link")" || continue
            __sandbox_view+=(--symlink "$target" "$link")
        elif [[ -d "$link" ]]; then
            __sandbox_view+=(--ro-bind "$link" "$link")
            [[ "$register" == true ]] &&
                SANDBOX_MOUNT_PASSTHROUGH+=("$link")
        else
            continue
        fi
        [[ "$register" == true ]] && SANDBOX_MOUNT_DESTINATIONS+=("$link")
    done
    return 0
}

sandbox_probe_argv() {
    local name="$1"
    local unshare_user="$2"
    local probe="$3"
    local -n __sandbox_probe="$name"

    __sandbox_probe=("$SANDBOX_BWRAP")
    sandbox_namespace_flags "$name" "$unshare_user" false
    sandbox_append_system_view "$name" false
    __sandbox_probe+=(--proc /proc --dev /dev --tmpfs /tmp -- "$probe")
}

sandbox_describe_argv() {
    [[ $# -gt 0 ]] || return 0
    printf '%q' "$1"
    shift
    [[ $# -gt 0 ]] && printf ' %q' "$@"
    printf '\n'
}

# Runs the narrowest sandbox that still proves a launch can work: first with an
# unprivileged user namespace, then without one for a setuid bubblewrap.
# Nothing of the DAW or of any prefix is involved — the probe only executes
# /usr/bin/true — and a host that fails both attempts never reaches a launch.
assert_sandbox_namespaces() {
    local probe attempt diagnostic
    local user_diagnostic="" user_probe=""
    local -a argv=()

    if [[ -z "$SANDBOX_BWRAP" ]]; then
        sandbox_error "bwrap was not resolved before the namespace preflight"
        return 1
    fi
    probe="$(sandbox_probe_command)" || return 1

    for attempt in true false; do
        argv=()
        sandbox_probe_argv argv "$attempt" "$probe"
        if diagnostic="$("${argv[@]}" 2>&1 >/dev/null)"; then
            SANDBOX_UNSHARE_USER="$attempt"
            SANDBOX_NAMESPACES_VERIFIED=true
            return 0
        fi
        if [[ "$attempt" == true ]]; then
            user_probe="$(sandbox_describe_argv "${argv[@]}")"
            user_diagnostic="$diagnostic"
        fi
    done

    sandbox_error "bubblewrap cannot create the namespaces this launcher requires"
    printf '  user namespace probe: %s' "$user_probe" >&2
    printf '  bwrap said:           %s\n' "${user_diagnostic:-<no output>}" >&2
    printf '  setuid probe:         %s' "$(sandbox_describe_argv "${argv[@]}")" >&2
    printf '  bwrap said:           %s\n' "${diagnostic:-<no output>}" >&2
    echo "Enable unprivileged user namespaces (for example" >&2
    echo "  sudo sysctl -w kernel.unprivileged_userns_clone=1)" >&2
    echo "or install a setuid bubblewrap, then run this launcher again." >&2
    echo "Refusing to launch without the read-only production boundary." >&2
    return 1
}

sandbox_register_destination() {
    local destination="$1"
    local existing

    for existing in ${SANDBOX_MOUNT_DESTINATIONS[@]+"${SANDBOX_MOUNT_DESTINATIONS[@]}"}; do
        if [[ "$existing" == "$destination" ]]; then
            sandbox_error "duplicate sandbox mount destination: $destination"
            return 1
        fi
    done
    SANDBOX_MOUNT_DESTINATIONS+=("$destination")
}

sandbox_add_mount() {
    local flag="$1"
    local -a arguments=("$@")
    local destination="${arguments[-1]}"

    sandbox_register_destination "$destination" || return 1
    SANDBOX_MOUNT_ARGUMENTS+=("$@")
    if [[ "$flag" == --ro-bind && "$2" == "$destination" ]]; then
        SANDBOX_MOUNT_PASSTHROUGH+=("$destination")
    fi
}

# True when host content is already visible read-only at this location. Only
# passthrough read-only binds count: a tmpfs or a kernel filesystem replaces
# what is there instead of exposing it.
sandbox_destination_is_covered() {
    local destination="$1"
    local existing

    for existing in ${SANDBOX_MOUNT_PASSTHROUGH[@]+"${SANDBOX_MOUNT_PASSTHROUGH[@]}"}; do
        if sandbox_path_within "$destination" "$existing"; then
            return 0
        fi
    done
    return 1
}

sandbox_add_read_only_input() {
    local source="$1"

    sandbox_destination_is_covered "$source" && return 0
    sandbox_add_mount --ro-bind "$source" "$source"
}

sandbox_add_optional_read_only() {
    local source="$1"
    local destination="$2"

    [[ -e "$source" ]] || return 0
    sandbox_destination_is_covered "$destination" && return 0
    sandbox_add_mount --ro-bind "$source" "$destination"
}

# A writable request may never be an ancestor of something already planned:
# that would silently shadow a narrower mount decided earlier.
sandbox_add_writable_mount() {
    local source="$1"
    local existing

    for existing in ${SANDBOX_MOUNT_DESTINATIONS[@]+"${SANDBOX_MOUNT_DESTINATIONS[@]}"}; do
        if [[ "$existing" != "$source" ]] &&
            sandbox_path_within "$existing" "$source"; then
            sandbox_error "writable path would shadow the sandbox mount at $existing: $source"
            return 1
        fi
    done
    sandbox_add_mount --bind "$source" "$source"
}

# Only the sockets a DAW actually needs, each at its own path. A socket that
# does not exist is skipped: an absent display or audio server must not turn
# into a failed launch or a broader mount.
sandbox_add_display_sockets() {
    local runtime_destination="$1"
    local display="${DISPLAY:-}"
    local runtime="${XDG_RUNTIME_DIR:-}"
    local number socket name authority

    if [[ "$display" == :* ]]; then
        number="${display#:}"
        number="${number%%.*}"
        if [[ "$number" =~ ^[0-9]+$ ]]; then
            sandbox_add_optional_read_only \
                "$SANDBOX_X11_SOCKET_DIR/X$number" \
                "$SANDBOX_X11_DESTINATION_DIR/X$number" || return 1
        fi
    fi

    name="${WAYLAND_DISPLAY:-}"
    if [[ -n "$name" && -n "$runtime" && "$name" != /* ]]; then
        sandbox_add_optional_read_only "$runtime/$name" \
            "$runtime_destination/$name" || return 1
    fi

    # An X authority file is the one real-home input an isolated run needs, and
    # it is exposed read-only as a single file.
    authority="${XAUTHORITY:-}"
    if [[ -n "$authority" && "$authority" == /* ]]; then
        sandbox_add_optional_read_only "$authority" "$authority" || return 1
    fi

    if [[ -n "$runtime" ]]; then
        for socket in "${SANDBOX_RUNTIME_SOCKETS[@]}"; do
            sandbox_add_optional_read_only "$runtime/$socket" \
                "$runtime_destination/$socket" || return 1
        done
    fi
    return 0
}

sandbox_require_directory() {
    local label="$1"
    local value="${2:-}"
    local canonical

    if [[ -z "$value" ]]; then
        sandbox_error "$label was not set; refusing to build a sandbox command"
        return 1
    fi
    if ! canonical="$(realpath -e -- "$value" 2>/dev/null)" ||
        [[ ! -d "$canonical" ]]; then
        sandbox_error "$label is not a usable directory: $value"
        return 1
    fi
    printf '%s\n' "$canonical"
}

build_bwrap_command() {
    if [[ $# -lt 2 ]]; then
        sandbox_error "build_bwrap_command requires OUTPUT_ARRAY DAW [ARGS...]"
        return 1
    fi

    local __sandbox_output_name="$1"
    shift
    local __sandbox_daw="$1"
    shift

    case "$__sandbox_output_name" in
        '' | __sandbox_* | *[^A-Za-z0-9_]*)
            sandbox_error "invalid sandbox command array name: $__sandbox_output_name"
            return 1
            ;;
    esac
    if [[ -z "$SANDBOX_BWRAP" ]]; then
        sandbox_error "bwrap was not resolved; refusing to build a sandbox command"
        return 1
    fi
    if [[ "$SANDBOX_NAMESPACES_VERIFIED" != true ]]; then
        sandbox_error "sandbox namespace support was not verified; refusing to build a sandbox command"
        return 1
    fi
    # Construction never resolves a DAW from scratch. The preflight owns that
    # decision, and this only ever confirms it.
    sandbox_require_resolved_daw || return 1

    local __sandbox_project __sandbox_prefix __sandbox_clone
    local __sandbox_isolation __sandbox_home
    __sandbox_project="$(sandbox_require_directory "the project root" \
        "$SANDBOX_PROJECT_ROOT")" || return 1
    __sandbox_prefix="$(sandbox_require_directory "the production prefix" \
        "$SANDBOX_REAL_PREFIX")" || return 1
    __sandbox_clone="$(sandbox_require_directory "the prefix clone" \
        "$SANDBOX_CLONE")" || return 1
    __sandbox_isolation="$(sandbox_require_directory "the isolation tree" \
        "$SANDBOX_ISOLATION")" || return 1
    __sandbox_home="$(sandbox_require_directory "the isolated home" \
        "$SANDBOX_ISOLATED_HOME")" || return 1

    sandbox_confirm_daw_executable "$__sandbox_daw" || return 1

    local __sandbox_runtime __sandbox_entry __sandbox_canonical
    local __sandbox_root __sandbox_install
    local -a __sandbox_argv=("$SANDBOX_BWRAP")
    __sandbox_runtime="/run/user/$(id -u)"

    SANDBOX_MOUNT_ARGUMENTS=()
    SANDBOX_MOUNT_DESTINATIONS=()
    SANDBOX_MOUNT_PASSTHROUGH=()

    sandbox_namespace_flags __sandbox_argv "$SANDBOX_UNSHARE_USER" \
        "$SANDBOX_NETWORK"
    sandbox_append_system_view __sandbox_argv true

    # Kernel interfaces and scratch space, before anything is placed inside
    # them. The runtime directory is a private tmpfs, so no host runtime state
    # is shared and nothing outlives the run.
    __sandbox_argv+=(--proc /proc --dev /dev)
    SANDBOX_MOUNT_DESTINATIONS+=(/proc /dev)
    for __sandbox_entry in ${SANDBOX_DEVICE_PATHS[@]+"${SANDBOX_DEVICE_PATHS[@]}"}; do
        [[ -e "$__sandbox_entry" ]] || continue
        sandbox_add_mount --dev-bind "$__sandbox_entry" "$__sandbox_entry" ||
            return 1
    done
    sandbox_add_mount --tmpfs /tmp || return 1
    sandbox_add_mount --tmpfs "$__sandbox_runtime" || return 1

    sandbox_add_display_sockets "$__sandbox_runtime" || return 1

    # Read-only inputs: the project tree, production state, the DAW itself and
    # any native plugin directory the user named.
    sandbox_add_mount --ro-bind "$__sandbox_project" "$__sandbox_project" ||
        return 1
    sandbox_add_read_only_input "$__sandbox_prefix" || return 1
    # A symlinked plugin root is exposed at its canonical name. `-L` is tested
    # too, so a dangling alias is refused here instead of vanishing quietly.
    for __sandbox_entry in "${SANDBOX_PLUGIN_ROOT_NAMES[@]}"; do
        __sandbox_root="$HOME/$__sandbox_entry"
        [[ -e "$__sandbox_root" || -L "$__sandbox_root" ]] || continue
        __sandbox_canonical="$(sandbox_plugin_root_target "$__sandbox_root")" ||
            return 1
        [[ -n "$__sandbox_canonical" ]] || continue
        sandbox_add_read_only_input "$__sandbox_canonical" || return 1
    done
    __sandbox_install="$(sandbox_daw_install_root "$SANDBOX_DAW_PATH")" ||
        return 1
    sandbox_add_read_only_input "$__sandbox_install" || return 1
    for __sandbox_entry in ${SANDBOX_NATIVE_PLUGIN_PATHS[@]+"${SANDBOX_NATIVE_PLUGIN_PATHS[@]}"}; do
        if ! __sandbox_canonical="$(realpath -e -- "$__sandbox_entry" \
            2>/dev/null)"; then
            sandbox_error "native plugin path does not resolve: $__sandbox_entry"
            return 1
        fi
        if sandbox_path_within "$__sandbox_canonical" "$__sandbox_clone" ||
            sandbox_path_within "$__sandbox_canonical" "$__sandbox_isolation"; then
            sandbox_error "native plugin path overlaps invocation-owned state: $__sandbox_canonical"
            return 1
        fi
        sandbox_add_read_only_input "$__sandbox_canonical" || return 1
    done

    # Writable state: the validated clone, this invocation's isolation tree,
    # and the paths the user approved by name. Nothing else.
    sandbox_add_writable_mount "$__sandbox_clone" || return 1
    sandbox_add_writable_mount "$__sandbox_isolation" || return 1
    for __sandbox_entry in ${SANDBOX_WRITABLE_PATHS[@]+"${SANDBOX_WRITABLE_PATHS[@]}"}; do
        sandbox_add_writable_mount "$__sandbox_entry" || return 1
    done

    __sandbox_argv+=(${SANDBOX_MOUNT_ARGUMENTS[@]+"${SANDBOX_MOUNT_ARGUMENTS[@]}"})
    __sandbox_argv+=(
        --setenv HOME "$__sandbox_home"
        --setenv XDG_CONFIG_HOME "$__sandbox_home/.config"
        --setenv XDG_DATA_HOME "$__sandbox_home/.local/share"
        --setenv XDG_CACHE_HOME "$__sandbox_home/.cache"
        --setenv XDG_RUNTIME_DIR "$__sandbox_runtime"
        --setenv WINEPREFIX "$__sandbox_clone"
        --chdir "$__sandbox_home"
        -- "$SANDBOX_DAW_PATH" "$@"
    )

    local -n __sandbox_output="$__sandbox_output_name"
    __sandbox_output=("${__sandbox_argv[@]}")
}
