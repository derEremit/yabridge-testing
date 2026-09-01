#!/bin/bash
# lib/sandbox.sh — build a fail-closed Bubblewrap command for an isolated DAW.
#
# The result is always an argv *array*, never a string that a shell has to
# re-parse, so a DAW argument may contain spaces, globs, quotes or leading
# dashes without changing what is executed.
#
# The boundary this file constructs:
#   - production Wine prefix and production plugin roots: read-only on the
#     host. Inside the sandbox the clone is bound over the production prefix
#     path (and ~/winplugins when that alias resolves there) so Bitwig keeps
#     seeing the paths it already indexed. Isolated yabridge directories are
#     bound over the resolved ~/.vst/yabridge, ~/.vst3/yabridge and
#     ~/.clap/yabridge directories (never onto those names when they are
#     symlinks; bwrap cannot mount there, and Bitwig still follows the
#     lexical path);
#   - the project tree (wine 11.8, test yabridge, env.sh): read-only;
#   - the validated clone and this invocation's isolation tree: writable;
#   - the real login home as HOME (Bitwig and Wine look up ~/.BitwigStudio
#     and known folders there). Only the Wine prefix overlay, isolated
#     yabridge plugin dirs, and isolated XDG for yabridgectl stay isolated.
#     Leftover first-run files under isolation/home/.BitwigStudio are not
#     HOME and must not win. --mac maps the process to root; Bitwig's Java
#     runtime then uses getpwuid (user.home=/root) and ignores $HOME, so
#     the sandbox also keeps the host uid and a files-only passwd whose
#     home is the real login home;
#   - host IPC and /dev/shm (no --unshare-ipc): Wine on Wayland still
#     talks to XWayland; X_ShmPutImage dies if SysV/POSIX shm is private;
#   - a new network namespace unless host networking was explicitly requested.
#     --mac creates user+net namespaces we own, starts pasta (or slirp4netns)
#     from the host netns attached to that netns, then runs real bwrap inside
#     it (no --unshare-net, no cross-userns nsenter). Pasta must not start
#     after unshare --net or it falls back to 169.254 local-mode.
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
# Real login home, snapshotted before yabridge generation changes HOME.
# The DAW's HOME is this path, not isolation/home.
SANDBOX_HOST_HOME="${SANDBOX_HOST_HOME:-}"
SANDBOX_HOST_UID="${SANDBOX_HOST_UID:-}"
SANDBOX_HOST_GID="${SANDBOX_HOST_GID:-}"
SANDBOX_HOST_USER="${SANDBOX_HOST_USER:-}"
# Never seeded from the environment: host networking is a decision the caller
# makes explicitly, so sourcing this file always starts from the closed state.
SANDBOX_NETWORK=false
SANDBOX_WRITABLE_PATHS=()
SANDBOX_NATIVE_PLUGIN_PATHS=()
# MAC identity is a command-line decision, never inherited from the
# environment. XLN's Wine Computer ID is the visible NIC MAC plus the
# Wine-facing iface name. Daily `xln-fj` uses Firejail macvlan on eno1
# (typically eth0 or eth0-<pid>); that path cannot be joined unprivileged.
# Firejail must also not parent bwrap (fbwrap) or run inside bwrap
# (--mac dropped). --mac therefore uses pasta (or slirp4netns) attached
# to a user+net ns we own. Pasta templates from --nic and names the
# namespace iface eth0 so Wine matches xln-fj. --address pins the guest
# IPv4 Wine sees (pasta --address); without it pasta copies the host
# template address. That is still userspace NAT, not Firejail macvlan.
SANDBOX_MAC=""
SANDBOX_NIC=""
SANDBOX_ADDRESS=""

# Resolved state.
SANDBOX_BWRAP=""
SANDBOX_DAW_PATH=""
SANDBOX_NAMESPACES_VERIFIED=false
SANDBOX_UNSHARE_USER=false
SANDBOX_UNSHARE=""
SANDBOX_PASTA=""
SANDBOX_SLIRP4NETNS=""
SANDBOX_MAC_BACKEND=""
SANDBOX_MAC_NETNS_EXEC=""
# Leftover pasta/slirp pid if a helper is interrupted; never inherited.
SANDBOX_MAC_HOLDER_PID=""

# Tests override the sysfs root so a missing host NIC cannot make
# command-construction fail on another machine. The NIC default follows the
# host's default route (pasta needs a template interface that actually
# routes); "eno1" is only the last resort when no default route exists.
SANDBOX_DEFAULT_MAC="02:00:5e:00:53:01"
if [[ -z "${SANDBOX_DEFAULT_NIC:-}" ]] &&
    command -v ip >/dev/null 2>&1 && command -v awk >/dev/null 2>&1; then
    SANDBOX_DEFAULT_NIC="$(ip -o route show default 2>/dev/null |
        awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}' || true)"
fi
SANDBOX_DEFAULT_NIC="${SANDBOX_DEFAULT_NIC:-eno1}"
SANDBOX_NIC_SYSFS="${SANDBOX_NIC_SYSFS:-/sys/class/net}"

# Host layout. This is configuration rather than user input; fixtures override
# it so command construction is deterministic on any machine.
SANDBOX_SYSTEM_ROOTS=(/usr /etc /opt /sys)
SANDBOX_USR_MERGE_LINKS=(/bin /sbin /lib /lib32 /lib64 /libx32)
SANDBOX_DEVICE_PATHS=(/dev/snd /dev/dri)
SANDBOX_RUNTIME_SOCKETS=(pulse/native pipewire-0)
SANDBOX_X11_SOCKET_DIR="/tmp/.X11-unix"
SANDBOX_X11_DESTINATION_DIR="/tmp/.X11-unix"
SANDBOX_PLUGIN_ROOT_NAMES=(.vst .vst3 .clap)
# Lexical names Bitwig may have stored for the production prefix. Added as
# extra overlay destinations only when they resolve to SANDBOX_REAL_PREFIX.
SANDBOX_PREFIX_ALIAS_RELATIVE=(winplugins .audio-production/winplugins)
SANDBOX_PROBE_COMMANDS=(/usr/bin/true /bin/true)
# XLN updater curl CAfile. ReplaceFileW deletes it on every start (error 77).
# The --ro-bind is this file only; it does not lock the updateBinary exe.
SANDBOX_XLN_INSTALLER_CAFILE="drive_c/ProgramData/XLN Audio/Temp/App/Cotton XLN Online Installer/updateBinary/installData/installData_app/cacert.pem"
SANDBOX_XLN_LAUNCHCOPY_CAFILE="drive_c/ProgramData/XLN Audio/Temp/App/Cotton XLN Online Installer/launchCopy/installData/installData_app/cacert.pem"
SANDBOX_XLN_CACERT_CACHE="run-state/xln-cacert.pem"
# Canonical installer the updater later remove_all's. Launch a sibling copy
# so Wine is not mapping the file it tries to delete (Access denied / 5).
SANDBOX_XLN_UPDATEBINARY_EXE="XLN Online Installer.exe"
SANDBOX_XLN_UPDATEBINARY_WIN_RE='^[A-Za-z]:[\\/]ProgramData[\\/]XLN Audio[\\/]Temp[\\/]App[\\/]Cotton XLN Online Installer[\\/]updateBinary[\\/]XLN Online Installer\.exe$'
SANDBOX_XLN_LAUNCH_COPY_WIN='ProgramData\XLN Audio\Temp\App\Cotton XLN Online Installer\launchCopy\XLN Online Installer.exe'
# Installed installer Wine ReplaceFileW cannot replace (clone only).
SANDBOX_XLN_PROGRAM_FILES_REL="drive_c/Program Files/XLN Audio/XLN Online Installer"
SANDBOX_XLN_PROGRAM_FILES_WIN='Program Files\XLN Audio\XLN Online Installer\XLN Online Installer.exe'
SANDBOX_XLN_LAUNCHCOPY_WIN_RE='^[A-Za-z]:[\\/]ProgramData[\\/]XLN Audio[\\/]Temp[\\/]App[\\/]Cotton XLN Online Installer[\\/]launchCopy[\\/]XLN Online Installer\.exe$'
SANDBOX_XLN_PROGRAM_FILES_WIN_RE='^[A-Za-z]:[\\/]Program Files[\\/]XLN Audio[\\/]XLN Online Installer[\\/]XLN Online Installer\.exe$'
# Host wineserver; set by daw-env from WINESERVER. Used to wait out an
# XLN self-restart inside the same bwrap.
SANDBOX_WINESERVER="${SANDBOX_WINESERVER:-}"
# Lua loads versioned resources from the exe directory (GetModuleFileName).
SANDBOX_XLN_RESOURCE_VERSION="XLN Online Installer/XLN Online Installer.version"
SANDBOX_XLN_RESOURCE_XPAK="XLN Online Installer/LuaSystem.xpak"

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

# Login home for plugin-root and prefix-alias paths. Prefer the snapshot so
# a later HOME remap for yabridge cannot retarget overlays onto isolation/.
sandbox_login_home() {
    if [[ -n "${SANDBOX_HOST_HOME:-}" ]]; then
        printf '%s\n' "$SANDBOX_HOST_HOME"
        return 0
    fi
    printf '%s\n' "$HOME"
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
        printf '%s\n' "$(sandbox_login_home)/$name"
        sandbox_canonical_alias "$(sandbox_login_home)/$name"
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

# The locations the sandbox creates for itself: kernel interfaces, the private
# scratch space, the private runtime directory and the display socket
# directory. Nothing a caller names may be one of these or sit above one,
# because Bubblewrap applies operations in order and a caller-supplied bind is
# planned after all of them.
sandbox_owned_destinations() {
    printf '%s\n' /proc /dev /tmp "/run/user/$(id -u)"
    [[ -n "$SANDBOX_X11_DESTINATION_DIR" ]] &&
        printf '%s\n' "$SANDBOX_X11_DESTINATION_DIR"
    return 0
}

# True for a system root this sandbox already binds read-only in full. A
# directory inside one of those is visible read-only at its own path whether or
# not anyone names it, so naming it adds no mount and can shadow nothing.
sandbox_is_read_only_system_root() {
    local candidate="$1"
    local root

    for root in "${SANDBOX_SYSTEM_ROOTS[@]}"; do
        [[ "$root" == "$candidate" ]] || continue
        [[ -d "$root" && ! -L "$root" ]] && return 0
    done
    return 1
}

# `--native-plugin-path` is the one option that both adds a read-only bind and
# puts a directory on the DAW's plugin search path, so a bad value is dangerous
# twice over: a broad bind planned this late replaces the narrower mounts
# already decided, and a path that reaches production bridges puts production
# yabridge back in front of the DAW.
#
# The value must therefore be a canonical directory that is neither the
# filesystem root, nor at or above the real home, nor at or above anything the
# sandbox owns, nor overlapping production, project, clone or isolation state
# under either its own name or the canonical name of a symlinked plugin root.
# The single allowance is a directory *inside* a read-only system root such as
# `/usr/lib/vst3`, which is already exposed exactly as it would be bound.
validate_sandbox_native_plugin_path() {
    local value="${1:-}"
    local canonical tree

    sandbox_assert_plain_path "--native-plugin-path" "$value" || return 1
    if ! canonical="$(realpath -e -- "$value" 2>/dev/null)"; then
        sandbox_error "--native-plugin-path does not exist: $value"
        return 1
    fi
    if [[ "$canonical" != "$value" ]]; then
        sandbox_error "--native-plugin-path must be a canonical path without symlinks: $value -> $canonical"
        return 1
    fi
    if [[ ! -d "$canonical" ]]; then
        sandbox_error "--native-plugin-path is not a directory: $canonical"
        return 1
    fi
    if [[ "$canonical" == / ]]; then
        sandbox_error "--native-plugin-path must not be the filesystem root: $canonical"
        return 1
    fi
    if sandbox_path_within "$HOME" "$canonical"; then
        sandbox_error "--native-plugin-path would expose the real home ($HOME): $canonical"
        return 1
    fi
    while IFS= read -r tree; do
        if sandbox_path_within "$tree" "$canonical"; then
            sandbox_error "--native-plugin-path would shadow the sandbox mount at $tree: $canonical"
            return 1
        fi
    done < <(sandbox_owned_destinations)
    while IFS= read -r tree; do
        sandbox_path_within "$canonical" "$tree" ||
            sandbox_path_within "$tree" "$canonical" || continue
        if [[ "$canonical" != "$tree" ]] &&
            sandbox_path_within "$canonical" "$tree" &&
            sandbox_is_read_only_system_root "$tree"; then
            continue
        fi
        sandbox_error "--native-plugin-path overlaps protected state ($tree): $canonical"
        return 1
    done < <(sandbox_protected_trees)
}

# A prefix that lives inside this project would be cloned into itself, bound
# read-only and writable at once, and recorded as the source of its own clone.
sandbox_assert_source_prefix() {
    local prefix="$SANDBOX_REAL_PREFIX"
    local tree

    if [[ -z "$prefix" ]]; then
        sandbox_error "the source prefix was not set; refusing to plan a sandbox"
        return 1
    fi
    for tree in "$SANDBOX_PROJECT_ROOT" "$SANDBOX_CLONE" "$SANDBOX_ISOLATION"; do
        [[ -n "$tree" ]] || continue
        if sandbox_path_within "$prefix" "$tree"; then
            sandbox_error "the source prefix is inside project state ($tree): $prefix"
            echo "Clone a prefix that lives outside this project tree." >&2
            return 1
        fi
    done
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

# Parents must be mounted before children. Binding ~/Documents/Bitwig Studio
# and then ~/Documents would shadow the narrower mount. Length is a sufficient
# order for these home-relative trees: a parent path is always shorter.
sandbox_writable_paths_parent_first() {
    local -a paths=()
    local -a sorted=()
    local path inserted
    local i

    paths=(${SANDBOX_WRITABLE_PATHS[@]+"${SANDBOX_WRITABLE_PATHS[@]}"})
    for path in ${paths[@]+"${paths[@]}"}; do
        inserted=false
        for ((i = 0; i < ${#sorted[@]}; i++)); do
            if [[ ${#path} -lt ${#sorted[i]} ]]; then
                sorted=("${sorted[@]:0:i}" "$path" "${sorted[@]:i}")
                inserted=true
                break
            fi
        done
        [[ "$inserted" == true ]] || sorted+=("$path")
    done
    SANDBOX_WRITABLE_PATHS=(${sorted[@]+"${sorted[@]}"})
}

# Login identity the DAW must see. Snapshotted before yabridge generation
# remaps HOME. Bitwig's Java runtime uses getpwuid(user.home), not $HOME,
# so uid 0 from --mac --map-root-user or bwrap --unshare-user would open
# /root/.BitwigStudio even when HOME is correct.
sandbox_snapshot_host_identity() {
    local home="${SANDBOX_HOST_HOME:-$HOME}"

    sandbox_assert_plain_path "the host home" "$home" || return 1
    if ! home="$(realpath -e -- "$home" 2>/dev/null)" || [[ ! -d "$home" ]]; then
        sandbox_error "the host home is not a usable directory: ${SANDBOX_HOST_HOME:-$HOME}"
        return 1
    fi
    SANDBOX_HOST_HOME="$home"
    if [[ -z "$SANDBOX_HOST_UID" ]]; then
        SANDBOX_HOST_UID="$(id -u)"
    fi
    if [[ -z "$SANDBOX_HOST_GID" ]]; then
        SANDBOX_HOST_GID="$(id -g)"
    fi
    if [[ -z "$SANDBOX_HOST_USER" ]]; then
        SANDBOX_HOST_USER="$(id -un)"
    fi
    if [[ ! "$SANDBOX_HOST_UID" =~ ^[0-9]+$ ]]; then
        sandbox_error "the host uid is not numeric: $SANDBOX_HOST_UID"
        return 1
    fi
    if [[ ! "$SANDBOX_HOST_GID" =~ ^[0-9]+$ ]]; then
        sandbox_error "the host gid is not numeric: $SANDBOX_HOST_GID"
        return 1
    fi
    if [[ -z "$SANDBOX_HOST_USER" || "$SANDBOX_HOST_USER" == *$'\n'* ]]; then
        sandbox_error "the host user name is unusable"
        return 1
    fi
}

sandbox_require_host_home() {
    local home isolated="${SANDBOX_ISOLATED_HOME:-}"

    sandbox_snapshot_host_identity || return 1
    home="$SANDBOX_HOST_HOME"
    if [[ -n "$isolated" ]]; then
        isolated="$(realpath -e -- "$isolated" 2>/dev/null || printf '%s\n' "$isolated")"
        if [[ "$home" == "$isolated" ]]; then
            sandbox_error "the DAW HOME would be the isolated tree ($home); refusing"
            return 1
        fi
    fi
    printf '%s\n' "$home"
}

# /etc is already bound read-only. Overlay a files-only passwd so getpwuid
# for root (uid 0 after --map-root-user) and the login uid both return the
# real home. Without this, Bitwig logs /root/.BitwigStudio.
sandbox_write_identity_files() {
    local isolation="$1"
    local dest="$isolation/sandbox-identity"
    local home="$SANDBOX_HOST_HOME"
    local uid="$SANDBOX_HOST_UID"
    local gid="$SANDBOX_HOST_GID"
    local user="$SANDBOX_HOST_USER"
    local saw_uid saw_root

    if ! mkdir -p -- "$dest"; then
        sandbox_error "could not create the sandbox identity directory: $dest"
        return 1
    fi
    if [[ -r /etc/passwd ]]; then
        if ! awk -F: -v home="$home" -v uid="$uid" '
            BEGIN { OFS = ":" }
            $3 == 0 || $3 == uid { $6 = home }
            { print }
        ' /etc/passwd > "$dest/passwd"; then
            sandbox_error "could not write the sandbox passwd overlay"
            return 1
        fi
    else
        if ! printf 'root:x:0:0::%s:/bin/bash\n%s:x:%s:%s::%s:/bin/bash\n' \
            "$home" "$user" "$uid" "$gid" "$home" > "$dest/passwd"; then
            sandbox_error "could not write the sandbox passwd overlay"
            return 1
        fi
    fi
    saw_root="$(awk -F: '$3 == 0 { found = 1 } END { print found + 0 }' \
        "$dest/passwd")"
    saw_uid="$(awk -F: -v uid="$uid" '$3 == uid { found = 1 }
        END { print found + 0 }' "$dest/passwd")"
    if [[ "$saw_root" != 1 ]]; then
        printf 'root:x:0:0::%s:/bin/bash\n' "$home" >> "$dest/passwd"
    fi
    if [[ "$saw_uid" != 1 && "$uid" != 0 ]]; then
        printf '%s:x:%s:%s::%s:/bin/bash\n' "$user" "$uid" "$gid" "$home" \
            >> "$dest/passwd"
    fi
    if ! printf 'passwd: files\ngroup: files\nshadow: files\n' \
        > "$dest/nsswitch.conf"; then
        sandbox_error "could not write the sandbox nsswitch overlay"
        return 1
    fi
    if [[ ! -s "$dest/passwd" ]]; then
        sandbox_error "the sandbox passwd overlay is empty"
        return 1
    fi
    printf '%s\n' "$dest"
}

sandbox_add_identity_overlays() {
    local isolation="$1"
    local dest

    dest="$(sandbox_write_identity_files "$isolation")" || return 1
    sandbox_add_mount --ro-bind "$dest/passwd" /etc/passwd || return 1
    sandbox_add_mount --ro-bind "$dest/nsswitch.conf" /etc/nsswitch.conf ||
        return 1
}

sandbox_add_host_home() {
    local home="$1"

    sandbox_add_writable_mount "$home" "$home"
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
    local name root native count index earlier

    sandbox_require_resolved_daw || return 1
    sandbox_daw_install_root "$SANDBOX_DAW_PATH" > /dev/null || return 1
    sandbox_assert_source_prefix || return 1
    for name in "${SANDBOX_PLUGIN_ROOT_NAMES[@]}"; do
        root="$(sandbox_login_home)/$name"
        [[ -e "$root" || -L "$root" ]] || continue
        sandbox_plugin_root_target "$root" > /dev/null || return 1
    done
    count="${#SANDBOX_NATIVE_PLUGIN_PATHS[@]}"
    for ((index = 0; index < count; index++)); do
        native="${SANDBOX_NATIVE_PLUGIN_PATHS[index]}"
        validate_sandbox_native_plugin_path "$native" || return 1
        for ((earlier = 0; earlier < index; earlier++)); do
            if [[ "${SANDBOX_NATIVE_PLUGIN_PATHS[earlier]}" == "$native" ]]; then
                sandbox_error "--native-plugin-path was already given: $native"
                return 1
            fi
        done
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

# XLN Computer ID is the adapter MAC, not /etc/machine-id. A value must be a
# single 6-octet address so it can be handed to pasta --mac-addr unchanged.
validate_sandbox_mac() {
    local value="${1:-}"

    if [[ -z "$value" ]]; then
        sandbox_error "--mac requires a value"
        return 1
    fi
    if [[ "$value" == -* ]]; then
        sandbox_error "--mac must not look like an option: $value"
        return 1
    fi
    if [[ ! "$value" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
        sandbox_error "--mac must be a 6-octet MAC address: $value"
        return 1
    fi
}

# --nic is the host template pasta --interface uses (xln-fj --net=eno1).
# The Wine-facing name is always eth0 (--ns-ifname), not this uplink.
# The name is validated when given so a typo is refused; it is not
# required for --mac (pasta then templates from the default route).
validate_sandbox_nic() {
    local value="${1:-}"
    local sysfs="${SANDBOX_NIC_SYSFS:-/sys/class/net}"

    if [[ -z "$value" ]]; then
        sandbox_error "--nic requires a value"
        return 1
    fi
    if [[ "$value" == -* ]]; then
        sandbox_error "--nic must not look like an option: $value"
        return 1
    fi
    if [[ "$value" == */* || "$value" == *\\* ]]; then
        sandbox_error "--nic must be an interface name, not a path: $value"
        return 1
    fi
    if [[ ! -e "$sysfs/$value" ]]; then
        sandbox_error "--nic is not a visible network interface: $value"
        return 1
    fi
}

# Guest IPv4 pasta --address assigns via DHCP. Daily xln-fj gets a LAN
# address on its macvlan; pasta otherwise copies the host template IP.
# Optional /prefix (0-32). IPv6 is refused: XLN's remaining delta is IPv4.
validate_sandbox_address() {
    local value="${1:-}"
    local ip prefix octet

    if [[ -z "$value" ]]; then
        sandbox_error "--address requires a value"
        return 1
    fi
    if [[ "$value" == -* ]]; then
        sandbox_error "--address must not look like an option: $value"
        return 1
    fi
    prefix=""
    ip="$value"
    if [[ "$value" == */* ]]; then
        ip="${value%%/*}"
        prefix="${value#*/}"
        if [[ "$ip" == *'/'* || -z "$ip" || -z "$prefix" ]]; then
            sandbox_error "--address must be an IPv4 address: $value"
            return 1
        fi
        if [[ ! "$prefix" =~ ^[0-9]+$ ]] || ((prefix > 32)); then
            sandbox_error "--address prefix must be 0-32: $value"
            return 1
        fi
    fi
    if [[ ! "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        sandbox_error "--address must be an IPv4 address: $value"
        return 1
    fi
    IFS=. read -r -a octet <<< "$ip"
    if ((${#octet[@]} != 4)); then
        sandbox_error "--address must be an IPv4 address: $value"
        return 1
    fi
    local part
    for part in "${octet[@]}"; do
        if ((10#$part > 255)); then
            sandbox_error "--address octet is out of range: $value"
            return 1
        fi
    done
}

sandbox_is_xln_identity_wrapper() {
    local path="${1:-}"
    local base

    [[ -n "$path" ]] || return 1
    base="$(basename -- "$path")"
    [[ "$base" == xln-fj ]]
}

sandbox_apply_xln_wrapper_identity() {
    if [[ -z "$SANDBOX_MAC" ]]; then
        SANDBOX_MAC="${XLN_MAC:-$SANDBOX_DEFAULT_MAC}"
    fi
    if [[ -z "$SANDBOX_NIC" ]]; then
        SANDBOX_NIC="${XLN_NIC:-$SANDBOX_DEFAULT_NIC}"
    fi
    SANDBOX_NETWORK=true
}

sandbox_resolve_command() {
    local label="$1"
    local name="$2"
    local resolved canonical

    if ! resolved="$(command -v -- "$name" 2>/dev/null)" ||
        [[ "$resolved" != /* ]]; then
        sandbox_error "$label was not found in PATH"
        return 1
    fi
    if ! canonical="$(realpath -e -- "$resolved" 2>/dev/null)" ||
        [[ ! -x "$canonical" ]]; then
        sandbox_error "$label is not an executable file: $resolved"
        return 1
    fi
    printf '%s\n' "$canonical"
}

require_unshare() {
    local canonical

    if ! canonical="$(sandbox_resolve_command unshare unshare)"; then
        echo "XLN MAC identity creates a user+net namespace with unshare, then" \
            "starts pasta from the host attached to that netns." >&2
        echo "Install util-linux (Arch: pacman -S util-linux) or drop --mac / xln-fj." >&2
        return 1
    fi
    SANDBOX_UNSHARE="$canonical"
}

sandbox_mac_netns_hint() {
    echo "XLN MAC identity needs pasta (preferred) or slirp4netns so Wine can" \
        "see a chosen MAC without Firejail+nsenter." >&2
    echo "Install pasta (Arch: pacman -S passt) or slirp4netns, or drop --mac / xln-fj." >&2
    echo "Firejail+nsenter is a dead end unprivileged: Firejail's netns lives" \
        "in its own user namespace and cannot be joined without capabilities" \
        "in the initial user namespace. Do not nest firejail around bwrap" \
        "(fbwrap replaces /usr/bin/bwrap) or firejail inside bwrap (--mac dropped)." >&2
}

require_mac_netns_backend() {
    local canonical

    SANDBOX_MAC_BACKEND=""
    SANDBOX_PASTA=""
    SANDBOX_SLIRP4NETNS=""
    if canonical="$(sandbox_resolve_command pasta pasta 2>/dev/null)"; then
        SANDBOX_PASTA="$canonical"
        SANDBOX_MAC_BACKEND=pasta
        return 0
    fi
    if canonical="$(sandbox_resolve_command slirp4netns slirp4netns 2>/dev/null)"; then
        SANDBOX_SLIRP4NETNS="$canonical"
        SANDBOX_MAC_BACKEND=slirp4netns
        return 0
    fi
    sandbox_error "pasta and slirp4netns were not found in PATH"
    sandbox_mac_netns_hint
    return 1
}

sandbox_mac_netns_helper() {
    local dir

    dir="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
    SANDBOX_MAC_NETNS_EXEC="$dir/mac-netns-exec.sh"
    if [[ ! -f "$SANDBOX_MAC_NETNS_EXEC" || ! -x "$SANDBOX_MAC_NETNS_EXEC" ]]; then
        sandbox_error "MAC netns helper is missing or not executable: $SANDBOX_MAC_NETNS_EXEC"
        return 1
    fi
}

stop_mac_netns_holder() {
    local pid="${SANDBOX_MAC_HOLDER_PID:-}"

    SANDBOX_MAC_HOLDER_PID=""
    [[ -n "$pid" ]] || return 0
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    fi
    if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    fi
}

# Helper starts on the host, creates user+net namespaces we own, starts
# pasta/slirp from the host netns attached to that netns, then execs the
# verified bwrap argv inside it. No nsenter into a foreign userns. bwrap
# must not --unshare-net.
wrap_launch_with_mac_identity() {
    if [[ $# -ne 2 ]]; then
        sandbox_error "wrap_launch_with_mac_identity requires OUTPUT_ARRAY INPUT_ARRAY"
        return 1
    fi

    local __mac_output_name="$1"
    local __mac_input_name="$2"

    case "$__mac_output_name" in
        '' | __mac_* | *[^A-Za-z0-9_]*)
            sandbox_error "invalid MAC identity array name: $__mac_output_name"
            return 1
            ;;
    esac
    case "$__mac_input_name" in
        '' | __mac_* | *[^A-Za-z0-9_]*)
            sandbox_error "invalid sandbox command array name: $__mac_input_name"
            return 1
            ;;
    esac

    local -n __mac_input="$__mac_input_name"

    if [[ -z "$SANDBOX_MAC" ]]; then
        sandbox_error "no MAC identity was requested; refusing to wrap the sandbox"
        return 1
    fi
    validate_sandbox_mac "$SANDBOX_MAC" || return 1
    if [[ -n "$SANDBOX_NIC" ]]; then
        validate_sandbox_nic "$SANDBOX_NIC" || return 1
    fi
    if [[ -n "$SANDBOX_ADDRESS" ]]; then
        validate_sandbox_address "$SANDBOX_ADDRESS" || return 1
    fi
    if [[ "$SANDBOX_NETWORK" != true ]]; then
        sandbox_error "MAC identity requires shared networking so the pasta netns is inherited"
        return 1
    fi
    local __mac_token
    for __mac_token in ${__mac_input[@]+"${__mac_input[@]}"}; do
        if [[ "$__mac_token" == --unshare-net ]]; then
            sandbox_error "MAC identity requires inheriting the pasta netns; bwrap must not --unshare-net"
            return 1
        fi
    done
    if [[ -z "$SANDBOX_UNSHARE" ]]; then
        require_unshare || return 1
    fi
    if [[ -z "$SANDBOX_MAC_BACKEND" ]]; then
        require_mac_netns_backend || return 1
    fi
    if [[ -n "$SANDBOX_ADDRESS" && "$SANDBOX_MAC_BACKEND" != pasta ]]; then
        sandbox_error "--address pins pasta --address; slirp4netns cannot assign a guest IPv4"
        return 1
    fi
    sandbox_mac_netns_helper || return 1
    if [[ -z "$SANDBOX_BWRAP" || "${__mac_input[0]}" != "$SANDBOX_BWRAP" ]]; then
        sandbox_error "MAC identity can only wrap the verified bwrap command"
        return 1
    fi

    local -n __mac_output="$__mac_output_name"
    __mac_output=(
        "$SANDBOX_MAC_NETNS_EXEC"
        --backend "$SANDBOX_MAC_BACKEND"
        --mac "$SANDBOX_MAC"
    )
    # Host template for pasta --interface. Wine-facing name is always eth0
    # (daily xln-fj / Firejail), not this uplink name.
    if [[ -n "$SANDBOX_NIC" ]]; then
        __mac_output+=(--nic "$SANDBOX_NIC")
    fi
    # Guest IPv4 Wine sees. Daily xln-fj DHCP is a LAN address; pasta
    # otherwise copies the host template (a NAT address).
    if [[ -n "$SANDBOX_ADDRESS" ]]; then
        __mac_output+=(--address "$SANDBOX_ADDRESS")
    fi
    __mac_output+=(--unshare "$SANDBOX_UNSHARE")
    if [[ "$SANDBOX_MAC_BACKEND" == pasta ]]; then
        __mac_output+=(--pasta "$SANDBOX_PASTA")
    else
        __mac_output+=(--slirp4netns "$SANDBOX_SLIRP4NETNS")
    fi
    __mac_output+=(-- "${__mac_input[@]}")
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

    # Share the host IPC namespace. Wine on Wayland still uses XWayland;
    # X_ShmPutImage (MIT-SHM) dies with BadValue if SysV shm is private.
    __sandbox_flags+=(--unshare-pid --unshare-uts)
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
    __sandbox_probe+=(--proc /proc --dev /dev)
    if [[ -d /dev/shm ]]; then
        __sandbox_probe+=(--bind /dev/shm /dev/shm)
    fi
    __sandbox_probe+=(--tmpfs /tmp -- "$probe")
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

    if [[ -L "$destination" ]]; then
        sandbox_error "sandbox mount destination is a symlink; bwrap cannot mount there: $destination -> $(readlink -- "$destination")"
        return 1
    fi
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
# that would silently shadow a narrower mount decided earlier. The destination
# is the host path by default; a remapped isolated-home destination is passed
# as the second argument.
sandbox_add_writable_mount() {
    local source="$1"
    local destination="${2:-$1}"
    local existing

    for existing in ${SANDBOX_MOUNT_DESTINATIONS[@]+"${SANDBOX_MOUNT_DESTINATIONS[@]}"}; do
        if [[ "$existing" != "$destination" ]] &&
            sandbox_path_within "$existing" "$destination"; then
            sandbox_error "writable path would shadow the sandbox mount at $existing: $destination"
            return 1
        fi
    done
    sandbox_add_mount --bind "$source" "$destination"
}

# Destinations where Bitwig may already have indexed the Wine prefix. The
# canonical production prefix is always included. A ~/winplugins symlink is
# not a mount dest (bwrap cannot mount onto a symlink); it stays a symlink
# and finds the clone through the overlay on the resolved prefix.
sandbox_prefix_overlay_destinations() {
    local dest resolved
    local prefix="$SANDBOX_REAL_PREFIX"
    local relative

    [[ -n "$prefix" ]] || return 0
    printf '%s\n' "$prefix"
    for relative in ${SANDBOX_PREFIX_ALIAS_RELATIVE[@]+"${SANDBOX_PREFIX_ALIAS_RELATIVE[@]}"}; do
        dest="$(sandbox_login_home)/$relative"
        [[ "$dest" != "$prefix" ]] || continue
        [[ -L "$dest" ]] && continue
        [[ -e "$dest" ]] || continue
        resolved="$(realpath -e -- "$dest" 2>/dev/null)" || continue
        [[ "$resolved" == "$prefix" ]] || continue
        printf '%s\n' "$dest"
    done
}

sandbox_destination_already_registered() {
    local dest="$1"
    local existing

    for existing in ${SANDBOX_MOUNT_DESTINATIONS[@]+"${SANDBOX_MOUNT_DESTINATIONS[@]}"}; do
        [[ "$existing" == "$dest" ]] && return 0
    done
    return 1
}

sandbox_add_prefix_overlays() {
    local clone="$1"
    local dest

    while IFS= read -r dest; do
        [[ -n "$dest" ]] || continue
        sandbox_destination_already_registered "$dest" && continue
        sandbox_add_writable_mount "$clone" "$dest" || return 1
    done < <(sandbox_prefix_overlay_destinations)
}

# After the clone is writable at its path and over the production prefix,
# pin XLN's curl CAfile read-only so Wine ReplaceFileW cannot delete it.
# The source is the project cache (under the read-only project tree), not
# the clone copy Wine can unlink. Destination is each cacert.pem file only
# — not the updateBinary exe and not the launchCopy directory.
sandbox_add_xln_cacert_ro_binds() {
    local rel src dest overlay
    local -a dests=()
    local -a rels=(
        "$SANDBOX_XLN_INSTALLER_CAFILE"
        "$SANDBOX_XLN_LAUNCHCOPY_CAFILE"
    )

    [[ -n "${SANDBOX_PROJECT_ROOT:-}" && -n "${SANDBOX_CLONE:-}" ]] || return 0
    src="$SANDBOX_PROJECT_ROOT/$SANDBOX_XLN_CACERT_CACHE"
    [[ -s "$src" ]] || return 0
    for rel in "${rels[@]}"; do
        [[ -e "$SANDBOX_CLONE/$rel" ]] || continue
        dests+=("$SANDBOX_CLONE/$rel")
        while IFS= read -r overlay; do
            [[ -n "$overlay" ]] || continue
            dests+=("$overlay/$rel")
        done < <(sandbox_prefix_overlay_destinations)
    done
    for dest in ${dests[@]+"${dests[@]}"}; do
        sandbox_destination_already_registered "$dest" && continue
        sandbox_add_mount --ro-bind "$src" "$dest" || return 1
    done
}

# Isolated yabridge writes under isolation/home. Bitwig already indexed the
# production ~/.vst/yabridge (and aliases). Overlay the isolated trees on the
# resolved host directory so the DAW still follows ~/.vst/yabridge and writes
# land on the isolated source. Never --bind onto ~/.vst itself when it is a
# symlink: bwrap cannot mount there.
sandbox_add_isolated_bridge_overlays() {
    local name root isolated dest canonical
    local home="${SANDBOX_ISOLATED_HOME:-}"

    [[ -n "$home" ]] || return 0
    for name in "${SANDBOX_PLUGIN_ROOT_NAMES[@]}"; do
        isolated="$home/$name/yabridge"
        [[ -d "$isolated" ]] || continue
        root="$(sandbox_login_home)/$name"
        dest="$root/yabridge"
        if [[ -e "$root" || -L "$root" ]]; then
            canonical="$(sandbox_plugin_root_target "$root")" || return 1
            if [[ -n "$canonical" ]]; then
                dest="$canonical/yabridge"
            fi
        fi
        [[ -d "$dest" ]] || continue
        sandbox_destination_already_registered "$dest" && continue
        sandbox_add_writable_mount "$isolated" "$dest" || return 1
    done
}

# Isolated yabridge still lives under isolation/home. HOME is the real login
# home, but hide those isolated plugin roots so a leftover first-run tree
# cannot be reindexed if something still looks under isolation/home.
sandbox_hide_isolated_plugin_roots() {
    local home="$1"
    local name dest

    for name in "${SANDBOX_PLUGIN_ROOT_NAMES[@]}"; do
        dest="$home/$name"
        [[ -d "$dest" ]] || continue
        sandbox_add_mount --tmpfs "$dest" || return 1
    done
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

# Wine apps resolve relative resources (XLN's XLN Online Installer/Certs/
# cacert.pem) from the process cwd. The DAW chdir is the login home; a
# Windows exe argument must start in that exe's directory on the clone.
# XLN's updater deletes installData_app/cacert.pem on every start
# (ReplaceFileW), then curl error 77. Restore the bundle on the clone
# and copy a host cache used for a later read-only bind (chattr +i is
# best-effort; CAP_LINUX_IMMUTABLE is often unavailable).
sandbox_pin_xln_installer_cacert() {
    local clone="$1"
    local cotton src dest dir cache
    local -a dests=()

    [[ -n "$clone" && -d "$clone/drive_c" ]] || return 0
    cotton="$clone/drive_c/ProgramData/XLN Audio/Temp/App/Cotton XLN Online Installer"
    src=""
    if [[ -s "$cotton/updateBinary/XLN Online Installer/Certs/cacert.pem" ]]; then
        src="$cotton/updateBinary/XLN Online Installer/Certs/cacert.pem"
    elif [[ -s "$cotton/XLN Online Installer/installData/installData_app/XLN Online Installer/Certs/cacert.pem" ]]; then
        src="$cotton/XLN Online Installer/installData/installData_app/XLN Online Installer/Certs/cacert.pem"
    elif [[ -s "$clone/drive_c/ProgramData/XLN Audio/XLN Online Installer/App/XLN Online Installer/Certs/cacert.pem" ]]; then
        src="$clone/drive_c/ProgramData/XLN Audio/XLN Online Installer/App/XLN Online Installer/Certs/cacert.pem"
    elif [[ -s /etc/ssl/certs/ca-certificates.crt ]]; then
        src="/etc/ssl/certs/ca-certificates.crt"
    else
        return 0
    fi
    dests=(
        "$cotton/updateBinary/installData/installData_app/cacert.pem"
        "$cotton/updateBinary/XLN Online Installer/Certs/cacert.pem"
        "$cotton/updateBinary/installData/installData_app/XLN Online Installer/Certs/cacert.pem"
    )
    # Relative Certs and the launchCopy CAfile, if daw-env staged a tree.
    if [[ -d "$cotton/launchCopy" ]]; then
        dests+=(
            "$cotton/launchCopy/XLN Online Installer/Certs/cacert.pem"
            "$cotton/launchCopy/installData/installData_app/cacert.pem"
            "$cotton/launchCopy/installData/installData_app/XLN Online Installer/Certs/cacert.pem"
        )
    fi
    for dest in "${dests[@]}"; do
        dir="$(dirname -- "$dest")"
        mkdir -p -- "$dir" || return 1
        if [[ -f "$dest" ]] && command -v chattr >/dev/null 2>&1; then
            chattr -i -- "$dest" 2>/dev/null || true
        fi
        if [[ "$src" != "$dest" ]]; then
            cp -f -- "$src" "$dest" || return 1
        fi
        chmod 644 -- "$dest" || true
        if command -v chattr >/dev/null 2>&1; then
            chattr +i -- "$dest" 2>/dev/null || true
        fi
    done
    if [[ -n "${SANDBOX_PROJECT_ROOT:-}" ]]; then
        cache="$SANDBOX_PROJECT_ROOT/$SANDBOX_XLN_CACERT_CACHE"
        mkdir -p -- "$(dirname -- "$cache")" || return 1
        if [[ "$src" != "$cache" ]]; then
            cp -f -- "$src" "$cache" || return 1
        fi
        chmod 644 -- "$cache" || true
    fi
}

# True when the last launch arg is the Cotton updateBinary installer
# (backslash or forward slash, any drive-letter case). That exact file
# is the one the updater later remove_all's.
sandbox_is_xln_updatebinary_installer() {
    local win="${1:-}"

    [[ "$win" =~ $SANDBOX_XLN_UPDATEBINARY_WIN_RE ]]
}

sandbox_is_xln_installer_win_arg() {
    local win="${1:-}"

    sandbox_is_xln_updatebinary_installer "$win" && return 0
    [[ "$win" =~ $SANDBOX_XLN_LAUNCHCOPY_WIN_RE ]] && return 0
    [[ "$win" =~ $SANDBOX_XLN_PROGRAM_FILES_WIN_RE ]] && return 0
    return 1
}

sandbox_daw_is_wine() {
    local base

    base="$(basename -- "${SANDBOX_DAW_PATH:-}")"
    [[ "$base" == wine || "$base" == wine64 ]]
}

sandbox_wine_wait_script() {
    local dest="${SANDBOX_PROJECT_ROOT:-}/lib/wine-wait.sh"

    if [[ -n "${SANDBOX_PROJECT_ROOT:-}" && -f "$dest" ]]; then
        chmod +x -- "$dest" 2>/dev/null || true
        printf '%s\n' "$dest"
        return 0
    fi
    sandbox_error "wine-wait.sh is missing under the project lib directory"
    return 1
}

# True when dir has the installer exe plus the versioned Lua resource tree
# GetModuleFileName loads from the exe directory (installData_app).
sandbox_xln_payload_complete() {
    local dir="$1"
    local app="$dir/installData/installData_app"

    [[ -f "$dir/$SANDBOX_XLN_UPDATEBINARY_EXE" ]] || return 1
    [[ -f "$app/$SANDBOX_XLN_RESOURCE_VERSION" ]] || return 1
    [[ -f "$app/$SANDBOX_XLN_RESOURCE_XPAK" ]] || return 1
}

# If updateBinary is a half-updated exe/resources split, copy a consistent
# installData tree from the Cotton bundle on this clone. Never reads the
# production prefix.
sandbox_repair_xln_updatebinary_payload() {
    local cotton="$1"
    local ub="$cotton/updateBinary"
    local bundle="$cotton/XLN Online Installer/installData"
    local bundle_exe="$bundle/installData_prg/$SANDBOX_XLN_UPDATEBINARY_EXE"

    sandbox_xln_payload_complete "$ub" && return 0
    [[ -d "$bundle/installData_app/XLN Online Installer" ]] || return 0

    mkdir -p -- "$ub/installData" || return 1
    cp -a -- "$bundle/installData_app" "$ub/installData/" || return 1
    if [[ -d "$bundle/installData_user" ]]; then
        cp -a -- "$bundle/installData_user" "$ub/installData/" || return 1
    fi
    if [[ ! -f "$ub/$SANDBOX_XLN_UPDATEBINARY_EXE" && -f "$bundle_exe" ]]; then
        cp -f -- "$bundle_exe" "$ub/$SANDBOX_XLN_UPDATEBINARY_EXE" || return 1
    fi
}

# Flat copy of payload contents into dest. Skips a nested updateBinary so
# Lua remove_all cannot target a locked path inside launchCopy.
sandbox_copy_xln_payload_contents() {
    local src_dir="$1"
    local dest_dir="$2"
    local entry base

    mkdir -p -- "$dest_dir" || return 1
    while IFS= read -r -d '' entry; do
        base="${entry##*/}"
        [[ "$base" == updateBinary ]] && continue
        if [[ -d "$entry" && ! -L "$entry" ]]; then
            mkdir -p -- "$dest_dir/$base" || return 1
            cp -a -- "$entry/." "$dest_dir/$base/" || return 1
        else
            cp -a -- "$entry" "$dest_dir/$base" || return 1
        fi
    done < <(find "$src_dir" -mindepth 1 -maxdepth 1 -print0)
}

# Copy a version-consistent snapshot of updateBinary *contents* to a
# sibling launchCopy/ on the clone only. Leaves the canonical exe in
# place so the updater can delete/replace it. Prints the launchCopy
# Windows path.
sandbox_stage_xln_updatebinary_launch_copy() {
    local clone="$1"
    local win="$2"
    local cotton src dest dest_dir ub_dir drive

    sandbox_is_xln_updatebinary_installer "$win" || return 1
    [[ -n "$clone" && -d "$clone/drive_c" ]] || return 1

    cotton="$clone/drive_c/ProgramData/XLN Audio/Temp/App/Cotton XLN Online Installer"
    ub_dir="$cotton/updateBinary"
    src="$ub_dir/$SANDBOX_XLN_UPDATEBINARY_EXE"
    [[ -f "$src" ]] || return 1

    sandbox_repair_xln_updatebinary_payload "$cotton" || return 1
    # Sync Program Files + App on the clone, then prefer that exe.
    # launchCopy is a Cotton bootstrapper: it ReplaceFileW's, ShellExecute's
    # Program Files, and exits. bwrap --die-with-parent then kills the child.
    sandbox_sync_xln_installed_from_updatebinary "$clone" || return 1

    drive="${win:0:1}"
    dest="$clone/$SANDBOX_XLN_PROGRAM_FILES_REL/$SANDBOX_XLN_UPDATEBINARY_EXE"
    if [[ -f "$dest" ]] && cmp -s -- "$src" "$dest"; then
        printf '%s:\\%s\n' "$drive" "$SANDBOX_XLN_PROGRAM_FILES_WIN"
        return 0
    fi

    dest_dir="$cotton/launchCopy"
    dest="$dest_dir/$SANDBOX_XLN_UPDATEBINARY_EXE"
    if [[ "$dest_dir" == "$ub_dir" ]]; then
        sandbox_error "XLN launchCopy must be a sibling of updateBinary, not the same path"
        return 1
    fi
    # Recreate so a prior exe-only launchCopy cannot leave Lua resources
    # missing ("Wrong resources").
    rm -rf -- "$dest_dir"
    mkdir -p -- "$dest_dir" || return 1
    sandbox_copy_xln_payload_contents "$ub_dir" "$dest_dir" || return 1
    [[ -f "$dest" ]] || return 1

    printf '%s:\\%s\n' "$drive" "$SANDBOX_XLN_LAUNCH_COPY_WIN"
}

# True when path (after resolving symlinks) is inside clone. A lexical
# prefix is not enough: Program Files can be a symlink out of the clone.
sandbox_xln_resolved_on_clone() {
    local clone="$1"
    local path="$2"
    local clone_real resolved

    clone_real="$(realpath -- "$clone")" || return 1
    if [[ -e "$path" || -L "$path" ]]; then
        resolved="$(realpath -- "$path")" || return 1
    else
        resolved="$(realpath -m -- "$path")" || return 1
    fi
    sandbox_path_within "$resolved" "$clone_real"
}

sandbox_xln_file_digest() {
    local file="$1"

    [[ -f "$file" ]] || return 1
    sha256sum -- "$file" | awk '{print $1}'
}

# Wine ReplaceFileW is a stub, so a Cotton self-update leaves the clone's
# Program Files installer at 4.7.2. The next launchCopy 4.7.3 still
# advertises 4_7_2, updates again, and quits. Copy the current
# updateBinary exe (and the resource tree the updater compares) onto
# that Program Files dir on this clone only, and only when the dest
# exe hash or version differs. Never reads the production prefix.
sandbox_sync_xln_program_files_from_updatebinary() {
    local clone="$1"
    local ub ub_exe pf_dir pf_exe app_src pf_res
    local ub_hash pf_hash

    [[ -n "$clone" && -d "$clone/drive_c" ]] || return 0
    ub="$clone/drive_c/ProgramData/XLN Audio/Temp/App/Cotton XLN Online Installer/updateBinary"
    ub_exe="$ub/$SANDBOX_XLN_UPDATEBINARY_EXE"
    [[ -f "$ub_exe" ]] || return 0
    sandbox_xln_resolved_on_clone "$clone" "$ub_exe" || {
        sandbox_error "XLN Program Files sync refuses an updateBinary path outside the clone"
        return 1
    }

    pf_dir="$clone/$SANDBOX_XLN_PROGRAM_FILES_REL"
    pf_exe="$pf_dir/$SANDBOX_XLN_UPDATEBINARY_EXE"
    [[ -d "$pf_dir" || -L "$pf_dir" ]] || return 0
    sandbox_xln_resolved_on_clone "$clone" "$pf_dir" || {
        sandbox_error "XLN Program Files sync refuses a path outside the clone"
        return 1
    }
    if [[ -e "$pf_exe" || -L "$pf_exe" ]]; then
        sandbox_xln_resolved_on_clone "$clone" "$pf_exe" || {
            sandbox_error "XLN Program Files sync refuses a path outside the clone"
            return 1
        }
    fi

    app_src="$ub/installData/installData_app/XLN Online Installer"
    pf_res="$pf_dir/XLN Online Installer"
    ub_hash="$(sandbox_xln_file_digest "$ub_exe")" || return 1
    pf_hash=""
    if [[ -f "$pf_exe" && ! -L "$pf_exe" ]]; then
        pf_hash="$(sandbox_xln_file_digest "$pf_exe")" || pf_hash=""
    fi
    if [[ -n "$pf_hash" && "$ub_hash" == "$pf_hash" ]]; then
        if [[ ! -f "$app_src/XLN Online Installer.version" ]] ||
            cmp -s -- "$app_src/XLN Online Installer.version" \
                "$pf_res/XLN Online Installer.version" 2>/dev/null; then
            return 0
        fi
    fi

    cp -f -- "$ub_exe" "$pf_exe" || return 1
    if [[ -d "$app_src" ]]; then
        mkdir -p -- "$pf_res" || return 1
        sandbox_xln_resolved_on_clone "$clone" "$pf_res" || {
            sandbox_error "XLN Program Files sync refuses a path outside the clone"
            return 1
        }
        cp -a -- "$app_src/." "$pf_res/" || return 1
    elif [[ -d "$ub/XLN Online Installer" ]]; then
        mkdir -p -- "$pf_res" || return 1
        sandbox_xln_resolved_on_clone "$clone" "$pf_res" || {
            sandbox_error "XLN Program Files sync refuses a path outside the clone"
            return 1
        }
        cp -a -- "$ub/XLN Online Installer/." "$pf_res/" || return 1
    fi
}

# Backward name: Program Files is the ReplaceFileW target. App resources
# stay on the clone when their version still lags updateBinary.
sandbox_sync_xln_installed_from_updatebinary() {
    local clone="$1"
    local ub app_src app_dest

    sandbox_sync_xln_program_files_from_updatebinary "$clone" || return 1

    [[ -n "$clone" && -d "$clone/drive_c" ]] || return 0
    ub="$clone/drive_c/ProgramData/XLN Audio/Temp/App/Cotton XLN Online Installer/updateBinary"
    app_src="$ub/installData/installData_app/XLN Online Installer"
    app_dest="$clone/drive_c/ProgramData/XLN Audio/XLN Online Installer/App/XLN Online Installer"
    [[ -d "$app_src" ]] || return 0
    sandbox_xln_resolved_on_clone "$clone" "$app_src" || {
        sandbox_error "XLN App sync refuses an updateBinary path outside the clone"
        return 1
    }
    if [[ -e "$app_dest" || -L "$app_dest" ]]; then
        sandbox_xln_resolved_on_clone "$clone" "$app_dest" || {
            sandbox_error "XLN App sync refuses a path outside the clone"
            return 1
        }
    else
        sandbox_xln_resolved_on_clone "$clone" "$(dirname -- "$app_dest")" || {
            sandbox_error "XLN App sync refuses a path outside the clone"
            return 1
        }
    fi
    if cmp -s -- "$app_src/XLN Online Installer.version" \
        "$app_dest/XLN Online Installer.version" 2>/dev/null; then
        return 0
    fi
    mkdir -p -- "$app_dest" || return 1
    sandbox_xln_resolved_on_clone "$clone" "$app_dest" || return 1
    cp -a -- "$app_src/." "$app_dest/" || return 1
}

# Rewrite an updateBinary installer argument to the launchCopy path
# after staging. Any other argument is printed unchanged.
sandbox_xln_updatebinary_launch_arg() {
    local clone="$1"
    local win="$2"
    local staged

    if sandbox_is_xln_updatebinary_installer "$win" &&
        staged="$(sandbox_stage_xln_updatebinary_launch_copy "$clone" "$win")"; then
        printf '%s\n' "$staged"
        return 0
    fi
    printf '%s\n' "$win"
}

sandbox_launch_chdir() {
    local host_home="$1"
    local win="$2"
    local unix dir

    if [[ "$win" != [A-Za-z]:[\\/]* ]]; then
        printf '%s\n' "$host_home"
        return 0
    fi
    unix="${win//\\//}"
    unix="${unix:2}"
    dir="$(dirname -- "${SANDBOX_CLONE}/drive_c${unix}")"
    if [[ -d "$dir" ]]; then
        printf '%s\n' "$dir"
        return 0
    fi
    printf '%s\n' "$host_home"
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
    local __sandbox_root __sandbox_install __sandbox_identity
    local __sandbox_host_home __sandbox_chdir
    local -a __sandbox_argv=("$SANDBOX_BWRAP")
    __sandbox_host_home="$(sandbox_require_host_home)" || return 1
    __sandbox_runtime="/run/user/$(id -u)"

    SANDBOX_MOUNT_ARGUMENTS=()
    SANDBOX_MOUNT_DESTINATIONS=()
    SANDBOX_MOUNT_PASSTHROUGH=()

    sandbox_namespace_flags __sandbox_argv "$SANDBOX_UNSHARE_USER" \
        "$SANDBOX_NETWORK"
    # Keep the login uid so Bitwig Java user.home is the real home, not
    # /root after --unshare-user or --mac --map-root-user.
    __sandbox_argv+=(--uid "$SANDBOX_HOST_UID" --gid "$SANDBOX_HOST_GID")
    sandbox_append_system_view __sandbox_argv true

    # Kernel interfaces and scratch space, before anything is placed inside
    # them. The runtime directory is a private tmpfs, so no host runtime state
    # is shared and nothing outlives the run.
    __sandbox_argv+=(--proc /proc --dev /dev)
    SANDBOX_MOUNT_DESTINATIONS+=(/proc /dev)
    # --dev /dev creates a private /dev/shm. Bind the host one so XWayland
    # MIT-SHM and POSIX shm match the shared IPC namespace.
    if [[ -d /dev/shm ]]; then
        sandbox_add_mount --bind /dev/shm /dev/shm || return 1
    fi
    for __sandbox_entry in ${SANDBOX_DEVICE_PATHS[@]+"${SANDBOX_DEVICE_PATHS[@]}"}; do
        [[ -e "$__sandbox_entry" ]] || continue
        sandbox_add_mount --dev-bind "$__sandbox_entry" "$__sandbox_entry" ||
            return 1
    done
    sandbox_add_mount --tmpfs /tmp || return 1
    sandbox_add_mount --tmpfs "$__sandbox_runtime" || return 1

    # Real login home first, before any file under it (XAUTHORITY) is bound
    # and before narrower overlays (project, prefix, yabridge). A later
    # ancestor bind would shadow those and is refused.
    sandbox_add_host_home "$__sandbox_host_home" || return 1
    sandbox_add_identity_overlays "$__sandbox_isolation" || return 1

    sandbox_add_display_sockets "$__sandbox_runtime" || return 1

    # Read-only inputs: the project tree, production plugin roots, the DAW
    # itself and any native plugin directory the user named. The production
    # prefix is not bound as itself; the clone is overlaid at that path later
    # so Bitwig keeps the host paths it already indexed.
    sandbox_add_mount --ro-bind "$__sandbox_project" "$__sandbox_project" ||
        return 1
    # A symlinked plugin root stays a symlink so Bitwig still sees
    # ~/.vst/yabridge. `-L` is tested too, so a dangling alias is refused
    # here instead of vanishing quietly. bwrap cannot mount onto the
    # symlink, so the read-only bind lands on the resolved directory.
    for __sandbox_entry in "${SANDBOX_PLUGIN_ROOT_NAMES[@]}"; do
        __sandbox_root="$(sandbox_login_home)/$__sandbox_entry"
        [[ -e "$__sandbox_root" || -L "$__sandbox_root" ]] || continue
        __sandbox_canonical="$(sandbox_plugin_root_target "$__sandbox_root")" ||
            return 1
        [[ -n "$__sandbox_canonical" ]] || continue
        sandbox_add_read_only_input "$__sandbox_canonical" || return 1
    done
    __sandbox_install="$(sandbox_daw_install_root "$SANDBOX_DAW_PATH")" ||
        return 1
    sandbox_add_read_only_input "$__sandbox_install" || return 1
    # Validated again where it is enforced. The preflight moves this refusal in
    # front of the clone and the bridge sync; this is the copy that decides
    # what is actually mounted.
    for __sandbox_entry in ${SANDBOX_NATIVE_PLUGIN_PATHS[@]+"${SANDBOX_NATIVE_PLUGIN_PATHS[@]}"}; do
        validate_sandbox_native_plugin_path "$__sandbox_entry" || return 1
        sandbox_add_read_only_input "$__sandbox_entry" || return 1
    done

    # Launch a copy of the XLN updateBinary installer so the canonical exe
    # is not the running image. Stage before the CAfile binds so launchCopy
    # installData_app/cacert.pem exists for a file-only --ro-bind.
    # sandbox_launch_chdir then uses this last arg.
    if [[ $# -gt 0 ]]; then
        set -- "${@:1:$(($#-1))}" \
            "$(sandbox_xln_updatebinary_launch_arg "$__sandbox_clone" "${@: -1}")"
    fi

    # Writable state: the validated clone at its own path and overlaid on the
    # production prefix path, isolated yabridge over production yabridge
    # paths, this invocation's isolation tree (with isolated plugin roots
    # then hidden), and extra paths the user approved. HOME is the real
    # login home already bound above; leftover isolation/home/.BitwigStudio
    # is not remapped and is not HOME.
    sandbox_add_writable_mount "$__sandbox_clone" || return 1
    sandbox_add_prefix_overlays "$__sandbox_clone" || return 1
    sandbox_add_xln_cacert_ro_binds || return 1
    sandbox_add_isolated_bridge_overlays || return 1
    sandbox_add_writable_mount "$__sandbox_isolation" || return 1
    sandbox_hide_isolated_plugin_roots "$__sandbox_home" || return 1
    sandbox_writable_paths_parent_first
    for __sandbox_entry in ${SANDBOX_WRITABLE_PATHS[@]+"${SANDBOX_WRITABLE_PATHS[@]}"}; do
        if sandbox_path_within "$__sandbox_entry" "$__sandbox_host_home"; then
            continue
        fi
        sandbox_add_writable_mount "$__sandbox_entry" || return 1
    done

    __sandbox_argv+=(${SANDBOX_MOUNT_ARGUMENTS[@]+"${SANDBOX_MOUNT_ARGUMENTS[@]}"})
    __sandbox_chdir="$__sandbox_host_home"
    if [[ $# -gt 0 ]]; then
        __sandbox_chdir="$(sandbox_launch_chdir "$__sandbox_host_home" "${@: -1}")"
    fi
    __sandbox_argv+=(
        --setenv HOME "$__sandbox_host_home"
        --setenv USER "$SANDBOX_HOST_USER"
        --setenv LOGNAME "$SANDBOX_HOST_USER"
        --setenv XDG_CONFIG_HOME "$__sandbox_home/.config"
        --setenv XDG_DATA_HOME "$__sandbox_home/.local/share"
        --setenv XDG_CACHE_HOME "$__sandbox_home/.cache"
        --setenv XDG_RUNTIME_DIR "$__sandbox_runtime"
        --setenv WINEPREFIX "$__sandbox_prefix"
        --chdir "$__sandbox_chdir"
    )
    # XLN ReplaceFileW + ShellExecute + exit: wine returns, bwrap tears
    # down, the replacement exe dies. Wait for wineserver so the restart
    # stays in this sandbox. fake-daw tests are unchanged.
    if [[ $# -gt 0 ]] && sandbox_daw_is_wine &&
        sandbox_is_xln_installer_win_arg "${@: -1}"; then
        local __sandbox_wait __sandbox_wineserver
        __sandbox_wait="$(sandbox_wine_wait_script)" || return 1
        __sandbox_wineserver="${SANDBOX_WINESERVER:-${WINESERVER:-}}"
        if [[ -n "$__sandbox_wineserver" ]]; then
            __sandbox_argv+=(--setenv WINESERVER "$__sandbox_wineserver")
        fi
        __sandbox_argv+=(-- "$__sandbox_wait" "$SANDBOX_DAW_PATH" "$@")
    else
        __sandbox_argv+=(-- "$SANDBOX_DAW_PATH" "$@")
    fi

    local -n __sandbox_output="$__sandbox_output_name"
    __sandbox_output=("${__sandbox_argv[@]}")
}
