#!/bin/bash

CLONE_PROVENANCE_NAME=".yabridge-staging-source"
CLONE_LOCK_FD=""
VALIDATED_CLONE_IDENTITY=""
OWNED_CLONE_CANDIDATE=""

clone_state_error() {
    echo "Error: $*" >&2
}

path_exists() {
    [[ -e "$1" || -L "$1" ]]
}

source_identity() {
    stat -Lc '%d %i' "$1"
}

clone_path_identity() {
    stat -c '%d %i' "$1"
}

report_provenance_mismatch() {
    local clone="$1"
    local source="$2"
    local clone_quoted provenance_quoted source_quoted

    printf -v clone_quoted '%q' "$clone"
    printf -v provenance_quoted '%q' "$clone/$CLONE_PROVENANCE_NAME"
    printf -v source_quoted '%q' "$source"

    clone_state_error "clone belongs to a different source prefix: $clone"
    echo "The clone was left untouched. Verify its recorded source and current source identity:" >&2
    echo "  cat -- $provenance_quoted" >&2
    echo "  stat -Lc 'device=%d inode=%i' -- $source_quoted" >&2
    echo "Remove it only after verifying that it is safe and disposable:" >&2
    echo "  rm -rf -- $clone_quoted" >&2
}

assert_separate_clone_paths() {
    local source="$1"
    local clone="$2"

    if [[ "$source" == "$clone" ]]; then
        clone_state_error "source and clone paths must be separate"
        return 1
    fi

    case "$clone/" in
        "$source/"*)
            clone_state_error "source and clone paths must not be nested"
            return 1
            ;;
    esac
    case "$source/" in
        "$clone/"*)
            clone_state_error "source and clone paths must not be nested"
            return 1
            ;;
    esac
}

assert_clone_destination_type() {
    local clone="$1"

    if [[ -L "$clone" ]]; then
        clone_state_error "clone destination is a symlink: $clone"
        return 1
    fi
    if [[ -e "$clone" && ! -d "$clone" ]]; then
        clone_state_error "clone destination is not a directory: $clone"
        return 1
    fi
}

acquire_clone_lock() {
    local root="$1"

    if ! command -v flock >/dev/null 2>&1; then
        clone_state_error "flock is required for safe clone creation (install util-linux)"
        return 1
    fi
    exec {CLONE_LOCK_FD}<"$root"
    if ! flock -n "$CLONE_LOCK_FD"; then
        clone_state_error "clone operation already in progress"
        exec {CLONE_LOCK_FD}<&-
        CLONE_LOCK_FD=""
        return 1
    fi
}

release_clone_lock() {
    if [[ -n "$CLONE_LOCK_FD" ]]; then
        flock -u "$CLONE_LOCK_FD"
        exec {CLONE_LOCK_FD}<&-
        CLONE_LOCK_FD=""
    fi
}

write_clone_provenance() {
    local clone="$1"
    local source="$2"
    local identity="$3"
    local device inode
    local provenance="$clone/$CLONE_PROVENANCE_NAME"
    local temporary="$clone/$CLONE_PROVENANCE_NAME.new.$$"

    read -r device inode <<< "$identity"
    rm -rf -- "$provenance" "$temporary"
    printf '%s\n%s\n%s\n' "$source" "$device" "$inode" > "$temporary"
    mv -T -- "$temporary" "$provenance"
}

validate_clone_provenance() {
    local clone="$1"
    local source="$2"
    local provenance="$clone/$CLONE_PROVENANCE_NAME"
    local expected_device expected_inode
    local -a fields=()

    assert_clone_destination_type "$clone" || return 1
    if [[ ! -d "$clone" ]]; then
        return 2
    fi
    if [[ ! -f "$provenance" || -L "$provenance" ]]; then
        clone_state_error "clone is incomplete (missing valid provenance): $clone"
        return 1
    fi
    if [[ ! -f "$clone/system.reg" || -L "$clone/system.reg" ]]; then
        clone_state_error "clone is incomplete (missing valid Wine state): $clone"
        return 1
    fi

    mapfile -t fields < "$provenance"
    if [[ "${#fields[@]}" -ne 3 ]]; then
        clone_state_error "clone is incomplete (malformed provenance): $clone"
        return 1
    fi

    read -r expected_device expected_inode <<< "$(source_identity "$source")"
    if [[ "${fields[0]}" != "$source" ||
          "${fields[1]}" != "$expected_device" ||
          "${fields[2]}" != "$expected_inode" ]]; then
        report_provenance_mismatch "$clone" "$source"
        return 1
    fi

    VALIDATED_CLONE_IDENTITY="$(clone_path_identity "$clone")"
}

validated_clone_identity_matches() {
    local clone="$1"

    [[ -n "$VALIDATED_CLONE_IDENTITY" &&
       ! -L "$clone" &&
       -d "$clone" &&
       "$(clone_path_identity "$clone")" == "$VALIDATED_CLONE_IDENTITY" ]]
}

cleanup_owned_clone_candidate() {
    if [[ -n "$OWNED_CLONE_CANDIDATE" &&
          ! -L "$OWNED_CLONE_CANDIDATE" &&
          -d "$OWNED_CLONE_CANDIDATE" ]]; then
        rm -rf -- "$OWNED_CLONE_CANDIDATE"
    fi
    OWNED_CLONE_CANDIDATE=""
}

require_atomic_exchange() {
    if ! mv --help 2>/dev/null | grep -Fq -- '--exchange'; then
        clone_state_error "GNU coreutils mv with --exchange support is required for atomic --fresh"
        echo "Please install or update GNU coreutils before refreshing this clone." >&2
        return 1
    fi
}

clone_prefix_atomic() {
    local source="$1"
    local clone="$2"
    local replace_existing="$3"
    local candidate="$clone.new.$$"
    local expected_source_identity

    expected_source_identity="$(source_identity "$source")"
    if [[ "$replace_existing" == true ]]; then
        require_atomic_exchange || return 1
    fi

    if path_exists "$candidate"; then
        clone_state_error "temporary clone path already exists; refusing ambiguous cleanup: $candidate"
        return 1
    fi

    OWNED_CLONE_CANDIDATE="$candidate"
    trap cleanup_owned_clone_candidate EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    echo "Cloning $source -> $clone"
    echo "  reflink copy-on-write — instant, near-zero disk, original only READ..."
    if ! cp -a --reflink=always "$source" "$candidate"; then
        echo "" >&2
        clone_state_error "reflink clone failed. This needs the project dir and the"
        echo "real prefix on the SAME btrfs/XFS filesystem. Aborting WITHOUT" >&2
        echo "falling back to a plain copy — your original is untouched." >&2
        cleanup_owned_clone_candidate
        trap - EXIT INT TERM
        return 1
    fi
    if [[ ! -d "$candidate" || -L "$candidate" ]]; then
        clone_state_error "reflink clone did not produce a safe directory"
        cleanup_owned_clone_candidate
        trap - EXIT INT TERM
        return 1
    fi
    if [[ "$(source_identity "$source")" != "$expected_source_identity" ]]; then
        clone_state_error "source prefix changed during cloning"
        cleanup_owned_clone_candidate
        trap - EXIT INT TERM
        return 1
    fi

    write_clone_provenance "$candidate" "$source" "$expected_source_identity"

    if [[ "$replace_existing" == true ]]; then
        if ! validated_clone_identity_matches "$clone"; then
            clone_state_error "validated clone changed before refresh"
            cleanup_owned_clone_candidate
            trap - EXIT INT TERM
            return 1
        fi
        if ! mv --exchange --no-copy -T -- "$candidate" "$clone"; then
            clone_state_error "could not atomically replace the existing clone"
            cleanup_owned_clone_candidate
            trap - EXIT INT TERM
            return 1
        fi
        rm -rf -- "$candidate"
    elif ! mv -T -- "$candidate" "$clone"; then
        clone_state_error "could not atomically activate the clone"
        cleanup_owned_clone_candidate
        trap - EXIT INT TERM
        return 1
    fi

    OWNED_CLONE_CANDIDATE=""
    trap - EXIT INT TERM
    echo "  Clone ready."
}

remove_validated_clone() {
    local clone="$1"

    if ! validated_clone_identity_matches "$clone"; then
        clone_state_error "validated clone changed before cleanup"
        return 1
    fi
    rm -rf -- "$clone"
    VALIDATED_CLONE_IDENTITY=""
}
