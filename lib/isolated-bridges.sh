#!/bin/bash
# lib/isolated-bridges.sh — generate yabridge bridges inside an invocation-owned
# isolated HOME/XDG tree that can only reference the validated prefix clone.
#
# The bridge tree lives at ROOT/isolation. yabridgectl only ever sees
# ROOT/isolation.new.$$/home as its HOME, so production yabridgectl
# configuration and production bridge roots are never read or written. New
# bridge state is built in that temporary sibling and activated with an atomic
# rename, so a failed sync or a rejected Windows target always leaves the
# previously validated bridge tree in place.

ISOLATED_BRIDGES_MARKER_NAME=".yabridge-staging-bridges"
ISOLATED_BRIDGES_MARKER_VERSION="yabridge-staging-bridges-v1"
ISOLATED_BRIDGES_REFRESH="${ISOLATED_BRIDGES_REFRESH:-false}"
ISOLATED_BRIDGES_ALLOW_EMPTY="${ISOLATED_BRIDGES_ALLOW_EMPTY:-false}"
ISOLATED_BRIDGES_EMPTY_REPORTED=false
ISOLATED_BRIDGE_RELATIVE_ROOTS=(".vst/yabridge" ".vst3/yabridge" ".clap/yabridge")
# Walk roots for isolated `yabridgectl add`, relative to the clone's drive_c.
# The clone root itself is never eligible: it contains dosdevices/, and Wine's
# z: commonly points at / or $HOME. drive_c as a whole is also ineligible
# because users/*/Documents (and Desktop, Downloads, ...) redirect into $HOME.
ISOLATED_PLUGIN_ADD_RELATIVE_ROOTS=(
    "Program Files"
    "Program Files (x86)"
    "VstPlugins"
    "Steinberg/VstPlugins"
)
ISOLATED_PLUGIN_ADD_ROOTS=()
ISOLATED_BRIDGE_SCAN_TEMPLATE_NAME="yabridge-bridge-scan.XXXXXX"
ISOLATED_BRIDGE_SCAN_ENTRIES=()
ISOLATED_BRIDGE_HOME=""
ISOLATED_BRIDGE_TARGET_COUNT=0
ISOLATED_BRIDGE_ACTIVE_IDENTITY=""
OWNED_BRIDGE_CANDIDATE=""
# The scan listing below is removed on every path the function itself takes. A
# signal arriving mid-traversal takes none of them, so the name is published
# here for the launcher's trap to finish the job.
OWNED_BRIDGE_SCAN_LISTING=""

isolated_bridges_error() {
    echo "Error: $*" >&2
}

isolated_bridges_path_exists() {
    [[ -e "$1" || -L "$1" ]]
}

isolated_bridge_path_identity() {
    stat -c '%d %i' -- "$1"
}

require_isolated_exchange() {
    if ! mv --help 2>/dev/null | grep -Fq -- '--exchange'; then
        isolated_bridges_error "GNU coreutils mv with --exchange support is required to refresh isolated bridges"
        echo "Please install or update GNU coreutils before refreshing bridges." >&2
        return 1
    fi
}

report_isolated_bridge_recovery() {
    local active="$1"
    local active_quoted marker_quoted

    printf -v active_quoted '%q' "$active"
    printf -v marker_quoted '%q' "$active/$ISOLATED_BRIDGES_MARKER_NAME"

    echo "The isolated bridge tree was left untouched. Inspect it first:" >&2
    echo "  cat -- $marker_quoted" >&2
    echo "Remove it only after verifying that it is safe and disposable:" >&2
    echo "  rm -rf -- $active_quoted" >&2
}

# Only reached when a tree that was reused rather than regenerated no longer
# validates, which is exactly the case a bridge refresh repairs.
report_isolated_bridge_refresh_hint() {
    local active="$1"

    echo "The reused isolated bridge tree at $active is stale or unusable." >&2
    echo "Regenerate it with --refresh-bridges, for example:" >&2
    echo "  ./daw-env.sh --refresh-bridges <daw-binary>" >&2
}

# Only ever removes a directory this invocation created for its own bridge
# candidate, so a concurrent launcher's candidate and any foreign sibling are
# always left alone.
cleanup_owned_bridge_candidate() {
    if [[ -n "$OWNED_BRIDGE_CANDIDATE" &&
        "$OWNED_BRIDGE_CANDIDATE" == */isolation.new."$$" &&
        ! -L "$OWNED_BRIDGE_CANDIDATE" &&
        -d "$OWNED_BRIDGE_CANDIDATE" ]]; then
        rm -rf -- "$OWNED_BRIDGE_CANDIDATE"
    fi
    OWNED_BRIDGE_CANDIDATE=""
}

# Only ever removes the listing this invocation created, under the name it was
# created with, so a concurrent launcher's listing is never touched.
cleanup_owned_bridge_scan_listing() {
    if [[ -n "$OWNED_BRIDGE_SCAN_LISTING" &&
        ! -L "$OWNED_BRIDGE_SCAN_LISTING" &&
        -f "$OWNED_BRIDGE_SCAN_LISTING" ]]; then
        rm -f -- "$OWNED_BRIDGE_SCAN_LISTING"
    fi
    OWNED_BRIDGE_SCAN_LISTING=""
}

# Windows plugin references are the only bridge entries that may point into the
# clone; everything else yabridgectl writes is a native chainloader copy.
# Extensions are matched case-insensitively so an uppercase reference can
# neither escape validation nor be missed when counting generated bridges.
isolated_bridge_metadata_kind() {
    local entry="$1"
    local root="$2"
    local relative="${entry#"$root"/}"

    case "${entry,,}" in
        *.dll | *.vst3-win | *.clap-win)
            printf 'windows\n'
            return 0
            ;;
    esac
    case "/${relative,,}" in
        */contents/x86_64-win/* | */contents/x86-win/*)
            printf 'windows\n'
            return 0
            ;;
    esac
    printf 'native\n'
}

# Every component between the isolated home and a bridge root must be a real
# directory at its expected location. A redirected intermediate component such
# as `.vst` is more dangerous than a redirected leaf, because the bridges inside
# it can still resolve into the clone while the directory handed to the DAW
# lives entirely outside the isolated tree.
assert_isolated_bridge_root_location() {
    local home_canonical="$1"
    local relative="$2"
    local expected="$home_canonical/$relative"
    local current="$home_canonical"
    local component root_canonical
    local -a components=()

    IFS='/' read -r -a components <<< "$relative"
    for component in "${components[@]}"; do
        current="$current/$component"
        if [[ -L "$current" ]]; then
            isolated_bridges_error "isolated bridge root is a symlink: $current"
            return 1
        fi
        if [[ -e "$current" && ! -d "$current" ]]; then
            isolated_bridges_error "isolated bridge root is not a directory: $current"
            return 1
        fi
    done

    [[ -d "$expected" ]] || return 0

    # Guards against a component being swapped between the walk above and the
    # traversal that follows.
    if ! root_canonical="$(realpath -e -- "$expected" 2>/dev/null)"; then
        isolated_bridges_error "isolated bridge root does not resolve: $expected"
        return 1
    fi
    if [[ "$root_canonical" != "$expected" ]]; then
        isolated_bridges_error "isolated bridge root resolves outside the isolated home: $expected -> $root_canonical"
        return 1
    fi
}

# find's exit status is never discarded: an unreadable directory or any other
# traversal error fails closed instead of validating a partial listing. The
# listing travels through a private temporary file because command substitution
# cannot carry the NUL separators that make arbitrary filenames safe.
scan_isolated_bridge_root() {
    local root="$1"
    local listing
    local find_status=0

    ISOLATED_BRIDGE_SCAN_ENTRIES=()
    if ! listing="$(mktemp -- \
        "${TMPDIR:-/tmp}/$ISOLATED_BRIDGE_SCAN_TEMPLATE_NAME")"; then
        isolated_bridges_error "could not create a temporary bridge listing for $root"
        return 1
    fi
    OWNED_BRIDGE_SCAN_LISTING="$listing"
    find "$root" -mindepth 1 -print0 > "$listing" || find_status=$?
    if [[ "$find_status" -ne 0 ]]; then
        cleanup_owned_bridge_scan_listing
        isolated_bridges_error "could not traverse the isolated bridge root: $root"
        return 1
    fi
    if ! mapfile -d '' -t ISOLATED_BRIDGE_SCAN_ENTRIES < "$listing"; then
        cleanup_owned_bridge_scan_listing
        ISOLATED_BRIDGE_SCAN_ENTRIES=()
        isolated_bridges_error "could not read the isolated bridge listing for $root"
        return 1
    fi
    cleanup_owned_bridge_scan_listing
}

validate_bridge_targets() {
    local home="$1"
    local copy="$2"
    local yabridge_home="${3:-}"
    local copy_canonical yabridge_canonical home_canonical
    local relative root entry kind target
    local windows_targets=0

    ISOLATED_BRIDGE_TARGET_COUNT=0
    yabridge_canonical=""

    if ! copy_canonical="$(realpath -e -- "$copy" 2>/dev/null)"; then
        isolated_bridges_error "cannot resolve the plugin clone for bridge validation: $copy"
        return 1
    fi
    if [[ -n "$yabridge_home" ]] &&
        ! yabridge_canonical="$(realpath -e -- "$yabridge_home" 2>/dev/null)"; then
        isolated_bridges_error "cannot resolve the yabridge home for bridge validation: $yabridge_home"
        return 1
    fi
    if [[ -L "$home" ]]; then
        isolated_bridges_error "isolated bridge home is a symlink: $home"
        return 1
    fi
    if ! home_canonical="$(realpath -e -- "$home" 2>/dev/null)" ||
        [[ ! -d "$home_canonical" ]]; then
        isolated_bridges_error "cannot resolve the isolated bridge home: $home"
        return 1
    fi

    for relative in "${ISOLATED_BRIDGE_RELATIVE_ROOTS[@]}"; do
        assert_isolated_bridge_root_location "$home_canonical" "$relative" ||
            return 1
        root="$home_canonical/$relative"
        [[ -d "$root" ]] || continue
        scan_isolated_bridge_root "$root" || return 1

        for entry in ${ISOLATED_BRIDGE_SCAN_ENTRIES[@]+"${ISOLATED_BRIDGE_SCAN_ENTRIES[@]}"}; do
            if [[ "$entry" == *$'\n'* || "$entry" == *$'\r'* ]]; then
                isolated_bridges_error "isolated bridge entry contains an unsupported newline"
                return 1
            fi
            kind="$(isolated_bridge_metadata_kind "$entry" "$root")"
            if [[ "$kind" == windows ]]; then
                if [[ ! -L "$entry" ]]; then
                    isolated_bridges_error "generated bridge metadata is not a Windows plugin symlink: $entry"
                    return 1
                fi
                if ! target="$(realpath -e -- "$entry" 2>/dev/null)"; then
                    isolated_bridges_error "generated bridge metadata does not resolve: $entry"
                    return 1
                fi
                if [[ "$target" != "$copy_canonical"/* ]]; then
                    isolated_bridges_error "generated bridge metadata escapes the plugin clone: $entry -> $target"
                    return 1
                fi
                windows_targets=$((windows_targets + 1))
            elif [[ -L "$entry" ]]; then
                if ! target="$(realpath -e -- "$entry" 2>/dev/null)"; then
                    isolated_bridges_error "isolated bridge symlink does not resolve: $entry"
                    return 1
                fi
                if [[ "$target" != "$copy_canonical"/* ]] &&
                    [[ -z "$yabridge_canonical" ||
                    "$target" != "$yabridge_canonical"/* ]]; then
                    isolated_bridges_error "isolated bridge symlink points outside the clone: $entry -> $target"
                    return 1
                fi
            fi
        done
    done

    ISOLATED_BRIDGE_SCAN_ENTRIES=()
    ISOLATED_BRIDGE_TARGET_COUNT="$windows_targets"
}

assert_bridge_output_present() {
    local copy="$1"

    if [[ "$ISOLATED_BRIDGE_TARGET_COUNT" -gt 0 ]]; then
        return 0
    fi
    if [[ "$ISOLATED_BRIDGES_ALLOW_EMPTY" == true ]]; then
        if [[ "$ISOLATED_BRIDGES_EMPTY_REPORTED" != true ]]; then
            echo "Warning: no isolated yabridge bridges were generated from $copy (--allow-empty)." >&2
            ISOLATED_BRIDGES_EMPTY_REPORTED=true
        fi
        return 0
    fi
    isolated_bridges_error "no isolated yabridge bridges were generated from $copy"
    echo "Refusing to launch without bridged plugins." >&2
    echo "Pass --allow-empty only for fixtures or diagnostics." >&2
    return 1
}

write_isolated_bridge_marker() {
    local candidate="$1"
    local copy_canonical="$2"
    local yabridge_canonical="$3"
    local marker="$candidate/$ISOLATED_BRIDGES_MARKER_NAME"

    printf '%s\n%s\n%s\n' "$ISOLATED_BRIDGES_MARKER_VERSION" \
        "$copy_canonical" "$yabridge_canonical" > "$marker"
}

# Returns 0 for a bridge tree this project generated for exactly these paths,
# 2 when no bridge tree exists yet, and 1 for anything foreign or unsafe.
inspect_isolated_bridge_state() {
    local active="$1"
    local copy_canonical="$2"
    local yabridge_canonical="$3"
    local marker="$active/$ISOLATED_BRIDGES_MARKER_NAME"
    local -a fields=()

    if [[ -L "$active" ]]; then
        isolated_bridges_error "isolated bridge tree is a symlink: $active"
        return 1
    fi
    if [[ ! -e "$active" ]]; then
        return 2
    fi
    if [[ ! -d "$active" ]]; then
        isolated_bridges_error "isolated bridge path is not a directory: $active"
        return 1
    fi
    if [[ ! -f "$marker" || -L "$marker" ]]; then
        isolated_bridges_error "isolated bridge state is foreign or incomplete: $active"
        report_isolated_bridge_recovery "$active"
        return 1
    fi

    mapfile -t fields < "$marker"
    if [[ "${#fields[@]}" -ne 3 ||
        "${fields[0]}" != "$ISOLATED_BRIDGES_MARKER_VERSION" ||
        "${fields[1]}" != "$copy_canonical" ||
        "${fields[2]}" != "$yabridge_canonical" ]]; then
        isolated_bridges_error "isolated bridge state is foreign or incomplete: $active"
        report_isolated_bridge_recovery "$active"
        return 1
    fi
    if [[ -L "$active/home" || ! -d "$active/home" ]]; then
        isolated_bridges_error "isolated bridge state is foreign or incomplete: $active"
        report_isolated_bridge_recovery "$active"
        return 1
    fi

    ISOLATED_BRIDGE_ACTIVE_IDENTITY="$(isolated_bridge_path_identity "$active")"
}

isolated_bridge_active_identity_matches() {
    local active="$1"

    [[ -n "$ISOLATED_BRIDGE_ACTIVE_IDENTITY" &&
        ! -L "$active" &&
        -d "$active" &&
        "$(isolated_bridge_path_identity "$active")" == "$ISOLATED_BRIDGE_ACTIVE_IDENTITY" ]]
}

# Packaged yabridgectl 5.1.1 panics on any `set` invocation: clap `path_auto`
# is not a SetTrue/SetFalse flag. Point the isolated tool at the built
# yabridge home by writing its config ourselves instead.
write_isolated_yabridgectl_config() {
    local home="$1"
    local yabridge_canonical="$2"
    local config_dir="$home/.config/yabridgectl"
    local config="$config_dir/config.toml"

    if [[ "$yabridge_canonical" == *$'\''* ]]; then
        isolated_bridges_error "yabridge home must not contain a single quote: $yabridge_canonical"
        return 1
    fi
    if ! mkdir -p -- "$config_dir"; then
        isolated_bridges_error "could not create isolated yabridgectl config directory: $config_dir"
        return 1
    fi
    if ! printf "yabridge_home = '%s'\n" "$yabridge_canonical" > "$config"; then
        isolated_bridges_error "could not write isolated yabridgectl config: $config"
        return 1
    fi
}

# Every yabridgectl call is confined to the candidate HOME/XDG tree, so it can
# neither read nor write production yabridgectl configuration.
#
# Bash prefix assignments are used instead of `env`: GNU env scans its leading
# arguments for `NAME=VALUE` pairs before deciding which one is the command, and
# no placement of `--` stops it from swallowing an executable path that contains
# `=`. `env NAME=1 -- cmd` fails outright because `--` becomes the command, and
# `env -- NAME=1 /opt/a=b/prog` treats the program path as another assignment.
run_isolated_yabridgectl() {
    local home="$1"
    local yabridgectl="$2"
    shift 2

    HOME="$home" \
        XDG_CONFIG_HOME="$home/.config" \
        XDG_DATA_HOME="$home/.local/share" \
        XDG_CACHE_HOME="$home/.cache" \
        "$yabridgectl" "$@"
}

# Collect yabridgectl walk roots that stay inside the clone's Windows tree.
# Existing candidates that resolve outside drive_c fail closed; missing
# candidates are skipped so a prefix without Program Files still syncs.
collect_isolated_plugin_add_roots() {
    local copy_canonical="$1"
    local drive_c="$copy_canonical/drive_c"
    local relative candidate resolved existing

    ISOLATED_PLUGIN_ADD_ROOTS=()

    if [[ -L "$drive_c" ]]; then
        isolated_bridges_error "clone Windows tree is a symlink: $drive_c"
        return 1
    fi
    if [[ ! -d "$drive_c" ]]; then
        return 0
    fi

    for relative in "${ISOLATED_PLUGIN_ADD_RELATIVE_ROOTS[@]}"; do
        candidate="$drive_c/$relative"
        isolated_bridges_path_exists "$candidate" || continue
        if ! resolved="$(realpath -e -- "$candidate" 2>/dev/null)"; then
            isolated_bridges_error "plugin add root does not resolve: $candidate"
            return 1
        fi
        if [[ ! -d "$resolved" ]]; then
            isolated_bridges_error "plugin add root is not a directory: $candidate"
            return 1
        fi
        if [[ "$resolved" != "$drive_c/"* ]]; then
            isolated_bridges_error \
                "plugin add root escapes the clone Windows tree: $candidate -> $resolved"
            return 1
        fi
        for existing in ${ISOLATED_PLUGIN_ADD_ROOTS[@]+"${ISOLATED_PLUGIN_ADD_ROOTS[@]}"}; do
            if [[ "$resolved" == "$existing" ]]; then
                continue 2
            fi
        done
        ISOLATED_PLUGIN_ADD_ROOTS+=("$resolved")
    done
}

generate_isolated_bridges() {
    local root="$1"
    local active="$2"
    local candidate="$3"
    local copy_canonical="$4"
    local yabridgectl="$5"
    local yabridge_canonical="$6"
    local active_status="$7"
    local candidate_home="$candidate/home"
    local relative

    if [[ -L "$root" || ! -d "$root" ]]; then
        isolated_bridges_error "project root is not a usable directory: $root"
        return 1
    fi
    if isolated_bridges_path_exists "$candidate"; then
        isolated_bridges_error "temporary bridge path already exists; refusing ambiguous cleanup: $candidate"
        return 1
    fi
    if [[ "$active_status" -eq 0 ]] && ! require_isolated_exchange; then
        return 1
    fi

    OWNED_BRIDGE_CANDIDATE="$candidate"
    if ! mkdir -p -- "$candidate_home/.config" "$candidate_home/.local/share" \
        "$candidate_home/.cache"; then
        isolated_bridges_error "could not create the isolated bridge candidate: $candidate"
        cleanup_owned_bridge_candidate
        return 1
    fi
    for relative in "${ISOLATED_BRIDGE_RELATIVE_ROOTS[@]}"; do
        if ! mkdir -p -- "$candidate_home/$relative"; then
            isolated_bridges_error "could not create isolated bridge root: $candidate_home/$relative"
            cleanup_owned_bridge_candidate
            return 1
        fi
    done

    echo "Generating isolated yabridge bridges for $copy_canonical..."
    if ! write_isolated_yabridgectl_config "$candidate_home" "$yabridge_canonical"; then
        isolated_bridges_error "could not point the isolated yabridgectl at $yabridge_canonical"
        cleanup_owned_bridge_candidate
        return 1
    fi
    if ! collect_isolated_plugin_add_roots "$copy_canonical"; then
        isolated_bridges_error "could not determine isolated plugin directories in $copy_canonical"
        cleanup_owned_bridge_candidate
        return 1
    fi
    if [[ "${#ISOLATED_PLUGIN_ADD_ROOTS[@]}" -gt 0 ]] &&
        ! run_isolated_yabridgectl "$candidate_home" "$yabridgectl" \
            add "${ISOLATED_PLUGIN_ADD_ROOTS[@]}"; then
        isolated_bridges_error "could not add isolated plugin directories to yabridgectl"
        cleanup_owned_bridge_candidate
        return 1
    fi
    if ! run_isolated_yabridgectl "$candidate_home" "$yabridgectl" \
        sync --force --prune; then
        isolated_bridges_error "isolated yabridgectl sync failed for $copy_canonical"
        cleanup_owned_bridge_candidate
        return 1
    fi

    if ! validate_bridge_targets "$candidate_home" "$copy_canonical" \
        "$yabridge_canonical"; then
        cleanup_owned_bridge_candidate
        return 1
    fi
    if ! assert_bridge_output_present "$copy_canonical"; then
        cleanup_owned_bridge_candidate
        return 1
    fi
    if ! write_isolated_bridge_marker "$candidate" "$copy_canonical" \
        "$yabridge_canonical"; then
        isolated_bridges_error "could not record isolated bridge provenance"
        cleanup_owned_bridge_candidate
        return 1
    fi

    if [[ "$active_status" -eq 0 ]]; then
        if ! isolated_bridge_active_identity_matches "$active"; then
            isolated_bridges_error "isolated bridge tree changed before activation"
            cleanup_owned_bridge_candidate
            return 1
        fi
        if ! mv --exchange --no-copy -T -- "$candidate" "$active"; then
            isolated_bridges_error "could not atomically activate the isolated bridge tree"
            cleanup_owned_bridge_candidate
            return 1
        fi
        rm -rf -- "$candidate"
    else
        if isolated_bridges_path_exists "$active"; then
            isolated_bridges_error "isolated bridge tree appeared during generation: $active"
            cleanup_owned_bridge_candidate
            return 1
        fi
        if ! mv -T -- "$candidate" "$active"; then
            isolated_bridges_error "could not activate the isolated bridge tree"
            cleanup_owned_bridge_candidate
            return 1
        fi
    fi

    OWNED_BRIDGE_CANDIDATE=""
    ISOLATED_BRIDGE_ACTIVE_IDENTITY="$(isolated_bridge_path_identity "$active")"
    echo "  Isolated bridges ready."
}

prepare_isolated_bridges() {
    if [[ $# -ne 4 ]]; then
        isolated_bridges_error "prepare_isolated_bridges requires ROOT COPY YABRIDGECTL YABRIDGE_HOME"
        return 1
    fi

    local root="$1"
    local copy="$2"
    local yabridgectl="$3"
    local yabridge_home="$4"
    local active="$root/isolation"
    local candidate="$root/isolation.new.$$"
    local copy_canonical yabridge_canonical path
    local active_status=0
    local regenerate=true

    if [[ -L "$copy" ]]; then
        isolated_bridges_error "plugin clone is a symlink: $copy"
        return 1
    fi
    if ! copy_canonical="$(realpath -e -- "$copy" 2>/dev/null)" ||
        [[ ! -d "$copy_canonical" ]]; then
        isolated_bridges_error "plugin clone is not a usable directory: $copy"
        return 1
    fi
    if ! yabridge_canonical="$(realpath -e -- "$yabridge_home" 2>/dev/null)" ||
        [[ ! -d "$yabridge_canonical" ]]; then
        isolated_bridges_error "yabridge home is not a usable directory: $yabridge_home"
        return 1
    fi
    if [[ ! -f "$yabridgectl" || ! -x "$yabridgectl" ]]; then
        isolated_bridges_error "yabridgectl is not an executable file: $yabridgectl"
        return 1
    fi
    for path in "$root" "$copy_canonical" "$yabridge_canonical"; do
        if [[ "$path" == *$'\n'* || "$path" == *$'\r'* ]]; then
            isolated_bridges_error "bridge paths must not contain newlines"
            return 1
        fi
    done

    inspect_isolated_bridge_state "$active" "$copy_canonical" \
        "$yabridge_canonical" || active_status=$?
    if [[ "$active_status" -eq 1 ]]; then
        return 1
    fi
    if [[ "$active_status" -eq 0 && "$ISOLATED_BRIDGES_REFRESH" != true ]]; then
        regenerate=false
    fi

    if [[ "$regenerate" == true ]]; then
        if ! generate_isolated_bridges "$root" "$active" "$candidate" \
            "$copy_canonical" "$yabridgectl" "$yabridge_canonical" \
            "$active_status"; then
            return 1
        fi
    else
        echo "Reusing isolated yabridge bridges: $active"
        echo "  (use --refresh-bridges to regenerate them)"
    fi

    # The activated tree is re-validated on every launch, including reuse, so a
    # bridge that started pointing outside the clone can never reach the DAW. A
    # reused tree that no longer validates is the one case a refresh repairs, so
    # say so instead of leaving the user with a bare rejection.
    if ! validate_bridge_targets "$active/home" "$copy_canonical" \
        "$yabridge_canonical"; then
        [[ "$regenerate" == true ]] || report_isolated_bridge_refresh_hint "$active"
        return 1
    fi
    if ! assert_bridge_output_present "$copy_canonical"; then
        [[ "$regenerate" == true ]] || report_isolated_bridge_refresh_hint "$active"
        return 1
    fi

    ISOLATED_BRIDGE_HOME="$active/home"
}

remove_isolated_bridges() {
    local root="$1"
    local active="$root/isolation"
    local marker="$active/$ISOLATED_BRIDGES_MARKER_NAME"
    local version=""

    if [[ -L "$active" ]]; then
        isolated_bridges_error "isolated bridge tree is a symlink; refusing to remove: $active"
        return 1
    fi
    if [[ ! -e "$active" ]]; then
        echo "No isolated bridges to remove: $active"
        return 0
    fi
    if [[ ! -d "$active" ]]; then
        isolated_bridges_error "isolated bridge path is not a directory; refusing to remove: $active"
        return 1
    fi
    if [[ ! -f "$marker" || -L "$marker" ]]; then
        isolated_bridges_error "isolated bridge state is foreign or incomplete; refusing to remove: $active"
        report_isolated_bridge_recovery "$active"
        return 1
    fi
    read -r version < "$marker" || true
    if [[ "$version" != "$ISOLATED_BRIDGES_MARKER_VERSION" ]]; then
        isolated_bridges_error "isolated bridge state is foreign or incomplete; refusing to remove: $active"
        report_isolated_bridge_recovery "$active"
        return 1
    fi

    echo "Removing $active..."
    rm -rf -- "$active"
    ISOLATED_BRIDGE_ACTIVE_IDENTITY=""
}

validate_native_plugin_path() {
    local value="${1:-}"

    if [[ -z "$value" || "$value" == -* ]]; then
        isolated_bridges_error "--native-plugin-path requires a value"
        return 1
    fi
    if [[ "$value" == *:* || "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
        isolated_bridges_error "--native-plugin-path must not contain ':' or newlines: $value"
        return 1
    fi
    if [[ "$value" != /* ]]; then
        isolated_bridges_error "--native-plugin-path must be an absolute path: $value"
        return 1
    fi
    if [[ ! -d "$value" ]]; then
        isolated_bridges_error "--native-plugin-path is not an existing directory: $value"
        return 1
    fi
}

# The DAW only ever sees the isolated bridge roots plus the native directories
# the user asked for by name; inherited production values are discarded. The
# bridge home comes from the validated preparation run, never from an argument.
export_isolated_plugin_paths() {
    local home="$ISOLATED_BRIDGE_HOME"
    local native vst2 vst3 clap

    if [[ -z "$home" ]]; then
        isolated_bridges_error "isolated bridge home is unknown; refusing to expose plugin paths"
        return 1
    fi
    vst2="$home/.vst/yabridge"
    vst3="$home/.vst3/yabridge"
    clap="$home/.clap/yabridge"
    for native in "$@"; do
        vst2+=":$native"
        vst3+=":$native"
        clap+=":$native"
    done

    export VST_PATH="$vst2"
    export VST3_PATH="$vst3"
    export CLAP_PATH="$clap"
}
