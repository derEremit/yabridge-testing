#!/bin/bash

read_state() {
    local key="$1" file="$2" line
    [[ "$key" =~ ^[A-Z0-9_]+$ && -f "$file" ]] || return 1
    line="$(grep -E "^${key}=[A-Za-z0-9._:/+@-]+$" "$file" | tail -n 1)" || return 1
    [[ -n "$line" ]] || return 1
    printf '%s\n' "${line#*=}"
}

write_state() {
    local file="$1" directory temporary entry
    shift
    directory="$(dirname "$file")"
    [[ -d "$directory" ]] || return 1
    temporary="$(mktemp "$directory/.component-state.XXXXXX")" || return 1

    for entry in "$@"; do
        if [[ ! "$entry" =~ ^[A-Z0-9_]+= ]] ||
            [[ "$entry" == *$'\n'* || "$entry" == *$'\r'* ]]; then
            rm -f "$temporary"
            return 1
        fi
        printf '%s\n' "$entry" >> "$temporary" || {
            rm -f "$temporary"
            return 1
        }
    done

    mv -f "$temporary" "$file"
}

component_matches() {
    local key="$1" expected="$2" file="$3" actual
    actual="$(read_state "$key" "$file")" || return 1
    [[ "$actual" == "$expected" ]]
}
