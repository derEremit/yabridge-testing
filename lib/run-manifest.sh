#!/bin/bash
# lib/run-manifest.sh — record the exact identities that govern one isolated DAW
# run, atomically, before that DAW is executed.
#
# The manifest answers one question after the fact: what did this run actually
# consist of? So nothing in it is carried over from an earlier phase on trust.
# Immediately before the document is written, the clone's provenance is checked
# against the live source prefix, the clone against the identity the launcher
# validated, every executable against its own canonical path, and the finished
# sandbox command against the policy the manifest is about to claim. An input
# that cannot be proven refuses the write, and a refused write refuses the
# launch: a run nobody can describe afterwards is not a run this project makes.
#
# JSON is produced by a short embedded Python encoder that reads scalars from
# the environment. The shell never interpolates a value into JSON text, so a
# path containing quotes, backslashes or Unicode cannot change the shape of the
# document, and a value that cannot be represented safely fails instead.
#
# The document is written to a private sibling temporary file, flushed to disk
# and renamed over the destination. A failure at any point therefore leaves the
# previous complete manifest exactly where it was, and only the temporary file
# this invocation created is ever removed.

RUN_MANIFEST_SCHEMA_VERSION=1
RUN_MANIFEST_NAME="run-manifest.json"
RUN_MANIFEST_TEMPORARY_TEMPLATE=".run-manifest.XXXXXX"

# The provenance record lib/clone-state.sh writes. Named here rather than read
# from a variable so nothing in the environment can redirect the identity this
# manifest claims to have verified.
RUN_MANIFEST_PROVENANCE_NAME=".yabridge-staging-source"

# The bridge directories lib/isolated-bridges.sh generates. tests/
# run_manifest.bats asserts that both lists stay identical.
RUN_MANIFEST_BRIDGE_RELATIVE_ROOTS=(".vst/yabridge" ".vst3/yabridge" ".clap/yabridge")

# Inputs the launcher fills in once every earlier phase has succeeded.
RUN_MANIFEST_SOURCE=""
RUN_MANIFEST_CLONE=""
RUN_MANIFEST_CLONE_IDENTITY=""
RUN_MANIFEST_STATE_FILE=""
RUN_MANIFEST_WINE_EXECUTABLE=""
RUN_MANIFEST_YABRIDGE_HOME=""
RUN_MANIFEST_YABRIDGECTL=""
RUN_MANIFEST_BRIDGE_HOME=""
RUN_MANIFEST_DAW=""
RUN_MANIFEST_BWRAP=""

# Never seeded from the environment. Each of these is a decision some earlier
# phase actually proved, so sourcing this file always starts from the state
# that claims nothing.
RUN_MANIFEST_NAMESPACES_VERIFIED=false
RUN_MANIFEST_UNSHARE_USER=false
RUN_MANIFEST_NETWORK=false
RUN_MANIFEST_QUIET_WINE=false
RUN_MANIFEST_WINEDEBUG_SET=false
RUN_MANIFEST_WINEDEBUG=""

# Resolved while writing.
RUN_MANIFEST_SOURCE_DEVICE=""
RUN_MANIFEST_SOURCE_INODE=""
RUN_MANIFEST_WINE_INSTALLED_VERSION=""
RUN_MANIFEST_WINE_VERSION_STRING=""
RUN_MANIFEST_NAMESPACE_MODE=""
RUN_MANIFEST_BRIDGE_ROOT_PATHS=()
RUN_MANIFEST_OWNED_TEMPORARY=""

run_manifest_error() {
    echo "Error: $*" >&2
}

# A path is only usable as an identity when it is absolute, free of newlines,
# present, and identical to its own canonical form. The last check is what
# rejects a symlink and every redirected component above it, so the manifest
# can only ever name the object the run really used.
run_manifest_canonical_path() {
    local label="$1"
    local value="${2:-}"
    local canonical

    if [[ -z "$value" ]]; then
        run_manifest_error "$label was not set; refusing to record this run"
        return 1
    fi
    if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
        run_manifest_error "$label must not contain newlines"
        return 1
    fi
    if [[ "$value" != /* ]]; then
        run_manifest_error "$label must be an absolute path: $value"
        return 1
    fi
    if [[ -L "$value" ]]; then
        run_manifest_error "$label must not be a symlink: $value"
        return 1
    fi
    if ! canonical="$(realpath -e -- "$value" 2>/dev/null)"; then
        run_manifest_error "$label does not exist: $value"
        return 1
    fi
    if [[ "$canonical" != "$value" ]]; then
        run_manifest_error "$label must be a canonical path: $value -> $canonical"
        return 1
    fi
    printf '%s\n' "$canonical"
}

run_manifest_require_directory() {
    local label="$1"
    local canonical

    canonical="$(run_manifest_canonical_path "$label" "${2:-}")" || return 1
    if [[ ! -d "$canonical" ]]; then
        run_manifest_error "$label is not a directory: $canonical"
        return 1
    fi
    printf '%s\n' "$canonical"
}

run_manifest_require_file() {
    local label="$1"
    local canonical

    canonical="$(run_manifest_canonical_path "$label" "${2:-}")" || return 1
    if [[ ! -f "$canonical" ]]; then
        run_manifest_error "$label is not a regular file: $canonical"
        return 1
    fi
    printf '%s\n' "$canonical"
}

run_manifest_require_executable() {
    local label="$1"
    local canonical

    canonical="$(run_manifest_require_file "$label" "${2:-}")" || return 1
    if [[ ! -x "$canonical" ]]; then
        run_manifest_error "$label is not executable: $canonical"
        return 1
    fi
    printf '%s\n' "$canonical"
}

run_manifest_boolean() {
    local label="$1"
    local value="${2:-}"

    if [[ "$value" != true && "$value" != false ]]; then
        run_manifest_error "$label must be true or false, not: $value"
        return 1
    fi
}

run_manifest_source_identity() {
    stat -Lc '%d %i' -- "$1"
}

run_manifest_clone_identity() {
    stat -c '%d %i' -- "$1"
}

# The clone's provenance record, read as three plain lines and never evaluated,
# accepted only when it still describes the source prefix this run validated.
# The device and inode recorded here are the ones the manifest publishes: a
# source that was replaced since the clone was made is a different source, and
# saying otherwise would be the one lie this file exists to prevent.
run_manifest_verify_provenance() {
    local clone="$1"
    local source="$2"
    local provenance="$clone/$RUN_MANIFEST_PROVENANCE_NAME"
    local device inode
    local -a fields=()

    if [[ -L "$provenance" || ! -f "$provenance" ]]; then
        run_manifest_error "clone provenance is missing or not a regular file: $provenance"
        return 1
    fi
    if ! mapfile -t fields < "$provenance"; then
        run_manifest_error "could not read clone provenance: $provenance"
        return 1
    fi
    if [[ "${#fields[@]}" -ne 3 ]]; then
        run_manifest_error "clone provenance is malformed: $provenance"
        return 1
    fi
    if [[ ! "${fields[1]}" =~ ^[0-9]+$ || ! "${fields[2]}" =~ ^[0-9]+$ ]]; then
        run_manifest_error "clone provenance is malformed: $provenance"
        return 1
    fi
    if [[ "${fields[0]}" != "$source" ]]; then
        run_manifest_error "clone provenance names a different source prefix: ${fields[0]}"
        return 1
    fi
    if ! read -r device inode <<< "$(run_manifest_source_identity "$source")"; then
        run_manifest_error "could not identify the source prefix: $source"
        return 1
    fi
    if [[ "${fields[1]}" != "$device" || "${fields[2]}" != "$inode" ]]; then
        run_manifest_error "the source prefix is no longer the one this clone was made from: $source"
        return 1
    fi

    RUN_MANIFEST_SOURCE_DEVICE="$device"
    RUN_MANIFEST_SOURCE_INODE="$inode"
}

# The clone the launcher validated, addressed by device and inode rather than
# by name, because a path stays equal across a rename and recreate.
run_manifest_verify_clone_identity() {
    local clone="$1"
    local current

    if [[ ! "$RUN_MANIFEST_CLONE_IDENTITY" =~ ^[0-9]+\ [0-9]+$ ]]; then
        run_manifest_error "the prefix clone was not validated before this run was recorded"
        return 1
    fi
    if ! current="$(run_manifest_clone_identity "$clone")"; then
        run_manifest_error "could not identify the prefix clone: $clone"
        return 1
    fi
    if [[ "$current" != "$RUN_MANIFEST_CLONE_IDENTITY" ]]; then
        run_manifest_error "the prefix clone changed after it was validated: $clone"
        return 1
    fi
}

# Component state is parsed by lib/component-state.sh, which matches a strict
# key and value shape instead of sourcing the file. A value that does not match
# is absent as far as this manifest is concerned, so an injected command never
# becomes a version string, let alone runs.
run_manifest_state_value() {
    local key="$1"
    local pattern="$2"
    local file="$3"
    local value

    if ! value="$(read_state "$key" "$file")" || [[ -z "$value" ]]; then
        run_manifest_error "component state does not record a usable $key: $file"
        echo "Run ./setup.sh to record the components this project installed." >&2
        return 1
    fi
    if [[ ! "$value" =~ $pattern ]]; then
        run_manifest_error "component state records a malformed $key: $value"
        return 1
    fi
    printf '%s\n' "$value"
}

# What the Wine executable says it is, compared against the version setup.sh
# recorded. A Wine binary swapped after installation answers differently, and
# the run is refused rather than recorded under the wrong identity.
run_manifest_wine_identity() {
    local executable="$1"
    local requested="$2"
    local observed installed

    if ! observed="$("$executable" --version 2>/dev/null)"; then
        run_manifest_error "the Wine executable did not report a version: $executable"
        return 1
    fi
    observed="${observed%%$'\n'*}"
    observed="${observed%$'\r'}"
    if [[ -z "$observed" ]]; then
        run_manifest_error "the Wine executable reported an empty version: $executable"
        return 1
    fi
    installed="${observed#wine-}"
    installed="${installed%% *}"
    if [[ "$installed" != "$requested" ]]; then
        run_manifest_error "the installed Wine is $installed, not the recorded $requested: $executable"
        echo "Run ./setup.sh to reinstall the recorded Wine version." >&2
        return 1
    fi

    RUN_MANIFEST_WINE_VERSION_STRING="$observed"
    RUN_MANIFEST_WINE_INSTALLED_VERSION="$installed"
}

run_manifest_bridge_roots() {
    local home="$1"
    local relative root

    RUN_MANIFEST_BRIDGE_ROOT_PATHS=()
    for relative in "${RUN_MANIFEST_BRIDGE_RELATIVE_ROOTS[@]}"; do
        root="$(run_manifest_require_directory \
            "the isolated bridge root $relative" "$home/$relative")" || return 1
        RUN_MANIFEST_BRIDGE_ROOT_PATHS+=("$root")
    done
}

# The finished argv, checked against the policy the manifest is about to claim.
# Only the arguments before the command separator are policy; everything after
# it belongs to the DAW and may look like anything at all.
run_manifest_verify_command() {
    local -n __run_manifest_command="$1"
    local bwrap="$2"
    local daw="$3"
    local total index argument
    local separator=-1
    local unshare_user=false
    local unshare_net=false

    total="${#__run_manifest_command[@]}"
    if [[ "$total" -lt 2 ]]; then
        run_manifest_error "the sandbox command is empty; refusing to record a sandboxed run"
        return 1
    fi
    if [[ "${__run_manifest_command[0]}" != "$bwrap" ]]; then
        run_manifest_error "the sandbox command does not start with the verified bwrap executable: ${__run_manifest_command[0]}"
        return 1
    fi
    for ((index = 1; index < total; index++)); do
        argument="${__run_manifest_command[index]}"
        if [[ "$argument" == -- ]]; then
            separator="$index"
            break
        fi
        case "$argument" in
            --unshare-user) unshare_user=true ;;
            --unshare-net) unshare_net=true ;;
        esac
    done
    if [[ "$separator" -lt 0 ]]; then
        run_manifest_error "the sandbox command has no command separator; refusing to record it"
        return 1
    fi
    if [[ "$((separator + 1))" -ge "$total" ||
        "${__run_manifest_command[separator + 1]}" != "$daw" ]]; then
        run_manifest_error "the sandbox command does not execute the recorded DAW: $daw"
        return 1
    fi
    if [[ "$RUN_MANIFEST_NETWORK" == true ]]; then
        if [[ "$unshare_net" == true ]]; then
            run_manifest_error "host networking was recorded, but the sandbox command unshares the network"
            return 1
        fi
    elif [[ "$unshare_net" != true ]]; then
        run_manifest_error "an isolated network was recorded, but the sandbox command does not unshare the network"
        return 1
    fi
    if [[ "$unshare_user" != "$RUN_MANIFEST_UNSHARE_USER" ]]; then
        run_manifest_error "the verified namespace mode does not match the sandbox command"
        return 1
    fi

    if [[ "$unshare_user" == true ]]; then
        RUN_MANIFEST_NAMESPACE_MODE="user"
    else
        RUN_MANIFEST_NAMESPACE_MODE="setuid"
    fi
}

# Only ever removes the temporary file this invocation created, so a concurrent
# launcher's temporary and any foreign sibling are always left alone.
run_manifest_discard_temporary() {
    if [[ -n "$RUN_MANIFEST_OWNED_TEMPORARY" &&
        ! -L "$RUN_MANIFEST_OWNED_TEMPORARY" &&
        -f "$RUN_MANIFEST_OWNED_TEMPORARY" ]]; then
        rm -f -- "$RUN_MANIFEST_OWNED_TEMPORARY"
    fi
    RUN_MANIFEST_OWNED_TEMPORARY=""
}

run_manifest_destination() {
    local destination="${1:-}"
    local directory canonical_directory

    if [[ -z "$destination" ]]; then
        run_manifest_error "no run manifest destination was given"
        return 1
    fi
    if [[ "$destination" == *$'\n'* || "$destination" == *$'\r'* ]]; then
        run_manifest_error "the run manifest destination must not contain newlines"
        return 1
    fi
    if [[ "$destination" != /* ]]; then
        run_manifest_error "the run manifest destination must be an absolute path: $destination"
        return 1
    fi
    if [[ -L "$destination" ]]; then
        run_manifest_error "the run manifest destination is a symlink: $destination"
        return 1
    fi
    if [[ -e "$destination" && ! -f "$destination" ]]; then
        run_manifest_error "the run manifest destination is not a regular file: $destination"
        return 1
    fi
    if [[ "$(basename -- "$destination")" != "$RUN_MANIFEST_NAME" ]]; then
        run_manifest_error "the run manifest must be named $RUN_MANIFEST_NAME: $destination"
        return 1
    fi
    directory="$(dirname -- "$destination")"
    canonical_directory="$(run_manifest_require_directory \
        "the run manifest directory" "$directory")" || return 1
    if [[ "$destination" != "$canonical_directory"/* ]]; then
        run_manifest_error "the run manifest destination is ambiguous: $destination"
        return 1
    fi
    printf '%s\n' "$destination"
}

write_run_manifest() {
    if [[ $# -ne 2 ]]; then
        run_manifest_error "write_run_manifest requires DESTINATION COMMAND_ARRAY"
        return 1
    fi

    local __run_manifest_name="$2"
    case "$__run_manifest_name" in
        '' | __run_manifest_* | *[^A-Za-z0-9_]*)
            run_manifest_error "invalid sandbox command array name: $__run_manifest_name"
            return 1
            ;;
    esac

    if ! declare -F read_state > /dev/null; then
        run_manifest_error "lib/component-state.sh must be sourced before a run manifest is written"
        return 1
    fi

    run_manifest_boolean "the verified sandbox flag" \
        "$RUN_MANIFEST_NAMESPACES_VERIFIED" || return 1
    run_manifest_boolean "the sandbox user namespace flag" \
        "$RUN_MANIFEST_UNSHARE_USER" || return 1
    run_manifest_boolean "the sandbox network policy" \
        "$RUN_MANIFEST_NETWORK" || return 1
    run_manifest_boolean "the quiet Wine option" \
        "$RUN_MANIFEST_QUIET_WINE" || return 1
    run_manifest_boolean "the effective WINEDEBUG state" \
        "$RUN_MANIFEST_WINEDEBUG_SET" || return 1
    if [[ "$RUN_MANIFEST_NAMESPACES_VERIFIED" != true ]]; then
        run_manifest_error "sandbox namespace support was not verified; refusing to record a sandboxed run"
        return 1
    fi
    if [[ "$RUN_MANIFEST_WINEDEBUG_SET" == true ]]; then
        if [[ "$RUN_MANIFEST_WINEDEBUG" == *$'\n'* ||
            "$RUN_MANIFEST_WINEDEBUG" == *$'\r'* ]]; then
            run_manifest_error "the effective WINEDEBUG value must not contain newlines"
            return 1
        fi
    fi
    # Quiet diagnostics are what the option means, not what a variable claims.
    if [[ "$RUN_MANIFEST_QUIET_WINE" == true &&
        ( "$RUN_MANIFEST_WINEDEBUG_SET" != true ||
        "$RUN_MANIFEST_WINEDEBUG" != "-all" ) ]]; then
        run_manifest_error "quiet Wine was requested, but the effective WINEDEBUG is not -all"
        return 1
    fi

    local __run_manifest_destination __run_manifest_source __run_manifest_clone
    local __run_manifest_state __run_manifest_wine __run_manifest_yabridge_home
    local __run_manifest_yabridgectl __run_manifest_bridge_home
    local __run_manifest_daw __run_manifest_bwrap
    local __run_manifest_wine_version __run_manifest_wine_digest
    local __run_manifest_yabridge_ref __run_manifest_yabridge_commit
    local __run_manifest_generated_at

    __run_manifest_destination="$(run_manifest_destination "$1")" || return 1
    __run_manifest_source="$(run_manifest_require_directory \
        "the source prefix" "$RUN_MANIFEST_SOURCE")" || return 1
    __run_manifest_clone="$(run_manifest_require_directory \
        "the prefix clone" "$RUN_MANIFEST_CLONE")" || return 1
    __run_manifest_bridge_home="$(run_manifest_require_directory \
        "the isolated bridge home" "$RUN_MANIFEST_BRIDGE_HOME")" || return 1
    __run_manifest_yabridge_home="$(run_manifest_require_directory \
        "the yabridge home" "$RUN_MANIFEST_YABRIDGE_HOME")" || return 1
    __run_manifest_state="$(run_manifest_require_file \
        "the component state file" "$RUN_MANIFEST_STATE_FILE")" || return 1
    __run_manifest_wine="$(run_manifest_require_executable \
        "the Wine executable" "$RUN_MANIFEST_WINE_EXECUTABLE")" || return 1
    __run_manifest_yabridgectl="$(run_manifest_require_executable \
        "the yabridgectl executable" "$RUN_MANIFEST_YABRIDGECTL")" || return 1
    __run_manifest_daw="$(run_manifest_require_executable \
        "the DAW executable" "$RUN_MANIFEST_DAW")" || return 1
    __run_manifest_bwrap="$(run_manifest_require_executable \
        "the bwrap executable" "$RUN_MANIFEST_BWRAP")" || return 1

    run_manifest_verify_provenance "$__run_manifest_clone" \
        "$__run_manifest_source" || return 1
    run_manifest_verify_clone_identity "$__run_manifest_clone" || return 1
    run_manifest_bridge_roots "$__run_manifest_bridge_home" || return 1

    __run_manifest_wine_version="$(run_manifest_state_value WINE_VERSION \
        '^[A-Za-z0-9][A-Za-z0-9._+-]*$' "$__run_manifest_state")" || return 1
    __run_manifest_wine_digest="$(run_manifest_state_value WINE_SHA256 \
        '^[0-9a-fA-F]{64}$' "$__run_manifest_state")" || return 1
    __run_manifest_yabridge_ref="$(run_manifest_state_value YABRIDGE_REF \
        '^[A-Za-z0-9][A-Za-z0-9._/+@-]*$' "$__run_manifest_state")" || return 1
    __run_manifest_yabridge_commit="$(run_manifest_state_value \
        YABRIDGE_COMMIT '^[0-9a-fA-F]{40}$' "$__run_manifest_state")" || return 1

    run_manifest_wine_identity "$__run_manifest_wine" \
        "$__run_manifest_wine_version" || return 1
    run_manifest_verify_command "$__run_manifest_name" \
        "$__run_manifest_bwrap" "$__run_manifest_daw" || return 1

    __run_manifest_generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)" || {
        run_manifest_error "could not read the current UTC time"
        return 1
    }
    if [[ ! "$__run_manifest_generated_at" =~ \
        ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
        run_manifest_error "could not format an unambiguous UTC timestamp"
        return 1
    fi

    run_manifest_encode "$__run_manifest_destination" \
        "$__run_manifest_generated_at" \
        "$__run_manifest_source" \
        "$__run_manifest_clone" \
        "$__run_manifest_wine" \
        "$__run_manifest_wine_version" \
        "${__run_manifest_wine_digest,,}" \
        "$__run_manifest_yabridge_ref" \
        "${__run_manifest_yabridge_commit,,}" \
        "$__run_manifest_yabridge_home" \
        "$__run_manifest_yabridgectl" \
        "$__run_manifest_bridge_home" \
        "$__run_manifest_daw" \
        "$__run_manifest_bwrap"
}

# Every value reaches the encoder as an environment scalar, so JSON is built by
# json.dump and never by the shell. The temporary file is created private, in
# the destination's own directory, opened without following a symlink, flushed,
# and only then renamed into place.
run_manifest_encode() {
    local destination="$1"
    local generated_at="$2"
    local source="$3"
    local clone="$4"
    local wine="$5"
    local wine_version="$6"
    local wine_digest="$7"
    local yabridge_ref="$8"
    local yabridge_commit="$9"
    local yabridge_home="${10}"
    local yabridgectl="${11}"
    local bridge_home="${12}"
    local daw="${13}"
    local bwrap="${14}"
    local directory temporary clone_device clone_inode index
    local -a root_environment=()

    directory="$(dirname -- "$destination")"
    if ! read -r clone_device clone_inode \
        <<< "$(run_manifest_clone_identity "$clone")"; then
        run_manifest_error "could not identify the prefix clone: $clone"
        return 1
    fi
    for index in "${!RUN_MANIFEST_BRIDGE_ROOT_PATHS[@]}"; do
        root_environment+=(
            "RUN_MANIFEST_JSON_BRIDGE_ROOT_$index=${RUN_MANIFEST_BRIDGE_ROOT_PATHS[index]}"
        )
    done

    if ! temporary="$(mktemp -- \
        "$directory/$RUN_MANIFEST_TEMPORARY_TEMPLATE")"; then
        run_manifest_error "could not create a private temporary run manifest in $directory"
        return 1
    fi
    RUN_MANIFEST_OWNED_TEMPORARY="$temporary"

    if ! env \
        "RUN_MANIFEST_JSON_SCHEMA_VERSION=$RUN_MANIFEST_SCHEMA_VERSION" \
        "RUN_MANIFEST_JSON_GENERATED_AT=$generated_at" \
        "RUN_MANIFEST_JSON_SOURCE_PATH=$source" \
        "RUN_MANIFEST_JSON_SOURCE_DEVICE=$RUN_MANIFEST_SOURCE_DEVICE" \
        "RUN_MANIFEST_JSON_SOURCE_INODE=$RUN_MANIFEST_SOURCE_INODE" \
        "RUN_MANIFEST_JSON_CLONE_PATH=$clone" \
        "RUN_MANIFEST_JSON_CLONE_DEVICE=$clone_device" \
        "RUN_MANIFEST_JSON_CLONE_INODE=$clone_inode" \
        "RUN_MANIFEST_JSON_WINE_REQUESTED_VERSION=$wine_version" \
        "RUN_MANIFEST_JSON_WINE_INSTALLED_VERSION=$RUN_MANIFEST_WINE_INSTALLED_VERSION" \
        "RUN_MANIFEST_JSON_WINE_SHA256=$wine_digest" \
        "RUN_MANIFEST_JSON_WINE_EXECUTABLE=$wine" \
        "RUN_MANIFEST_JSON_WINE_VERSION_STRING=$RUN_MANIFEST_WINE_VERSION_STRING" \
        "RUN_MANIFEST_JSON_YABRIDGE_REQUESTED_REF=$yabridge_ref" \
        "RUN_MANIFEST_JSON_YABRIDGE_COMMIT=$yabridge_commit" \
        "RUN_MANIFEST_JSON_YABRIDGE_HOME=$yabridge_home" \
        "RUN_MANIFEST_JSON_YABRIDGECTL_PATH=$yabridgectl" \
        "RUN_MANIFEST_JSON_BRIDGE_HOME=$bridge_home" \
        "RUN_MANIFEST_JSON_BRIDGE_ROOT_COUNT=${#RUN_MANIFEST_BRIDGE_ROOT_PATHS[@]}" \
        "${root_environment[@]}" \
        "RUN_MANIFEST_JSON_DAW_EXECUTABLE=$daw" \
        "RUN_MANIFEST_JSON_SANDBOX_ENABLED=$RUN_MANIFEST_NAMESPACES_VERIFIED" \
        "RUN_MANIFEST_JSON_SANDBOX_BWRAP=$bwrap" \
        "RUN_MANIFEST_JSON_SANDBOX_NAMESPACE_MODE=$RUN_MANIFEST_NAMESPACE_MODE" \
        "RUN_MANIFEST_JSON_SANDBOX_NETWORK=$RUN_MANIFEST_NETWORK" \
        "RUN_MANIFEST_JSON_QUIET_WINE=$RUN_MANIFEST_QUIET_WINE" \
        "RUN_MANIFEST_JSON_WINEDEBUG_SET=$RUN_MANIFEST_WINEDEBUG_SET" \
        "RUN_MANIFEST_JSON_WINEDEBUG=$RUN_MANIFEST_WINEDEBUG" \
        python3 - "$temporary" <<'PY'
import json
import os
import sys

PREFIX = "RUN_MANIFEST_JSON_"


def text(name):
    try:
        value = os.environ[PREFIX + name]
    except KeyError:
        raise SystemExit(f"manifest field {name} was not provided")
    if "\n" in value or "\r" in value:
        raise SystemExit(f"manifest field {name} contains a newline")
    return value


def boolean(name):
    value = text(name)
    if value not in ("true", "false"):
        raise SystemExit(f"manifest field {name} is not a boolean: {value}")
    return value == "true"


def number(name):
    value = text(name)
    if not value.isdigit():
        raise SystemExit(f"manifest field {name} is not a number: {value}")
    return int(value)


document = {
    "schema_version": number("SCHEMA_VERSION"),
    "generated_at": text("GENERATED_AT"),
    "source_path": text("SOURCE_PATH"),
    "source_device": number("SOURCE_DEVICE"),
    "source_inode": number("SOURCE_INODE"),
    "clone_path": text("CLONE_PATH"),
    "clone_device": number("CLONE_DEVICE"),
    "clone_inode": number("CLONE_INODE"),
    "wine_requested_version": text("WINE_REQUESTED_VERSION"),
    "wine_installed_version": text("WINE_INSTALLED_VERSION"),
    "wine_sha256": text("WINE_SHA256"),
    "wine_executable": text("WINE_EXECUTABLE"),
    "wine_version_string": text("WINE_VERSION_STRING"),
    "yabridge_requested_ref": text("YABRIDGE_REQUESTED_REF"),
    "yabridge_commit": text("YABRIDGE_COMMIT"),
    "yabridge_home": text("YABRIDGE_HOME"),
    "yabridgectl_path": text("YABRIDGECTL_PATH"),
    "bridge_home": text("BRIDGE_HOME"),
    "bridge_roots": [
        text(f"BRIDGE_ROOT_{index}") for index in range(number("BRIDGE_ROOT_COUNT"))
    ],
    "daw_executable": text("DAW_EXECUTABLE"),
    "sandbox": {
        "enabled": boolean("SANDBOX_ENABLED"),
        "bwrap": text("SANDBOX_BWRAP"),
        "namespace_mode": text("SANDBOX_NAMESPACE_MODE"),
        "network": boolean("SANDBOX_NETWORK"),
    },
    "wine_diagnostics": {
        "quiet": boolean("QUIET_WINE"),
        "winedebug": text("WINEDEBUG") if boolean("WINEDEBUG_SET") else None,
    },
}

descriptor = os.open(sys.argv[1], os.O_WRONLY | os.O_TRUNC | os.O_NOFOLLOW)
with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
    json.dump(document, handle, ensure_ascii=False, indent=2, sort_keys=True)
    handle.write("\n")
    handle.flush()
    os.fsync(handle.fileno())
PY
    then
        run_manifest_error "could not encode the run manifest for $destination"
        run_manifest_discard_temporary
        return 1
    fi

    if ! mv -T -- "$temporary" "$destination"; then
        run_manifest_error "could not atomically replace the run manifest: $destination"
        run_manifest_discard_temporary
        return 1
    fi
    RUN_MANIFEST_OWNED_TEMPORARY=""
}
