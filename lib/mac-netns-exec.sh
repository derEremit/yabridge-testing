#!/bin/bash
# Creates a user+net namespace we own, starts pasta (preferred) or
# slirp4netns from the *host* netns so pasta can still see host routes,
# attaches that helper to the new netns, then execs real bwrap inside the
# same userns+netns. bwrap must not --unshare-net.
#
# Pasta started after `unshare --net` sees no host NICs and falls back to
# 169.254 local-mode (NAT to 127.0.0.1). The PID --netns form also needs
# --userns or setns into the netns fails with EPERM. There is no
# cross-userns nsenter into Firejail, and no firejail/bwrap nesting.
set -euo pipefail

backend=""
mac=""
nic=""
address=""
pasta=""
slirp=""
unshare_bin=""
ready=""
in_netns=false
pasta_argv0_dir=""
hold_dir=""
# Wine-facing name. Daily xln-fj / Firejail macvlan is eth0 or eth0-<pid>.
# Pasta otherwise copies the host template name (eno1), which XLN can treat
# as a different Computer ID even when the MAC matches.
guest_ifname="eth0"

mac_netns_error() {
    echo "Error: $*" >&2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --backend)
            backend="${2:-}"
            shift 2
            ;;
        --mac)
            mac="${2:-}"
            shift 2
            ;;
        --nic)
            nic="${2:-}"
            shift 2
            ;;
        --address)
            address="${2:-}"
            shift 2
            ;;
        --pasta)
            pasta="${2:-}"
            shift 2
            ;;
        --slirp4netns)
            slirp="${2:-}"
            shift 2
            ;;
        --unshare)
            unshare_bin="${2:-}"
            shift 2
            ;;
        --ready)
            ready="${2:-}"
            shift 2
            ;;
        --in-netns)
            in_netns=true
            shift
            ;;
        --)
            shift
            break
            ;;
        *)
            mac_netns_error "unknown MAC netns helper option: $1"
            exit 1
            ;;
    esac
done

if [[ -z "$backend" || -z "$mac" ]]; then
    mac_netns_error "MAC netns helper requires --backend and --mac"
    exit 1
fi
if [[ $# -eq 0 ]]; then
    mac_netns_error "MAC netns helper requires a command after --"
    exit 1
fi

sysfs="${SANDBOX_NIC_SYSFS:-/sys/class/net}"
backend_pid=""
holder_pid=""
mac_norm="$(printf '%s\n' "$mac" | tr 'A-F' 'a-f')"
self="$0"

cleanup_mac_backend() {
    local pid="${backend_pid:-}"
    local child="${holder_pid:-}"
    local argv0_dir="${pasta_argv0_dir:-}"
    local dir="${hold_dir:-}"
    backend_pid=""
    holder_pid=""
    pasta_argv0_dir=""
    hold_dir=""
    if [[ -n "$pid" ]]; then
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        fi
        if kill -0 "$pid" 2>/dev/null; then
            kill -9 "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        fi
    fi
    if [[ -n "$child" ]]; then
        if kill -0 "$child" 2>/dev/null; then
            kill "$child" 2>/dev/null || true
            wait "$child" 2>/dev/null || true
        fi
    fi
    if [[ -n "$argv0_dir" ]]; then
        rm -rf -- "$argv0_dir"
    fi
    if [[ -n "$dir" ]]; then
        rm -rf -- "$dir"
    fi
}

sysfs_has_mac() {
    local address seen

    for address in "$sysfs"/*/address; do
        [[ -f "$address" ]] || continue
        seen="$(tr 'A-F' 'a-f' < "$address" | tr -d '[:space:]')"
        if [[ "$seen" == "$mac_norm" ]]; then
            return 0
        fi
    done
    return 1
}

ip_link_has_mac() {
    local seen link

    command -v ip >/dev/null 2>&1 || return 1
    while IFS= read -r link; do
        seen="$(printf '%s\n' "$link" | tr 'A-F' 'a-f')"
        if [[ "$seen" == *"link/ether ${mac_norm}"* ]]; then
            return 0
        fi
    done < <(ip -o link 2>/dev/null || true)
    return 1
}

netns_has_mac() {
    sysfs_has_mac || ip_link_has_mac
}

# bwrap --ro-bind /sys /sys copies whatever /sys this process sees.
# unshare --net does not remount sysfs, so host /sys hides the pasta tap.
# A private mount ns + fresh sysfs makes the MAC visible inside the sandbox.
run_with_netns_sysfs() {
    if sysfs_has_mac || [[ "$sysfs" != /sys/class/net ]]; then
        "$@"
        return
    fi
    if ! command -v unshare >/dev/null 2>&1 ||
        ! command -v mount >/dev/null 2>&1; then
        "$@"
        return
    fi
    unshare --mount --propagation private -- \
        /bin/bash -c 'mount -t sysfs -o nosuid,nodev,noexec sysfs /sys && exec "$@"' \
        _ "$@"
}

wait_for_mac_interface() {
    local attempt

    for ((attempt = 0; attempt < 50; attempt++)); do
        if [[ -n "${backend_pid:-}" ]] && ! kill -0 "$backend_pid" 2>/dev/null; then
            mac_netns_error "$backend exited before presenting MAC $mac"
            return 1
        fi
        if netns_has_mac; then
            return 0
        fi
        sleep 0.05
    done
    mac_netns_error "$backend did not present MAC $mac"
    return 1
}

# Pasta --userns /proc/<pid>/ns/user fails with EINVAL ("Couldn't enter
# user namespace") if unshare has not finished --map-root-user yet.
wait_for_holder_namespaces() {
    local pid="$1"
    local attempt

    if [[ -z "$pid" ]]; then
        mac_netns_error "MAC identity user+net namespace pid is missing"
        return 1
    fi
    for ((attempt = 0; attempt < 50; attempt++)); do
        if ! kill -0 "$pid" 2>/dev/null; then
            mac_netns_error "MAC identity user+net namespace exited before pasta could attach"
            return 1
        fi
        # uid_map is empty until unshare --map-root-user finishes. After
        # a short wait, attach anyway if the holder is still alive so
        # restricted /proc views cannot stall forever.
        if [[ -s "/proc/$pid/uid_map" ]] || ((attempt >= 5)); then
            return 0
        fi
        sleep 0.05
    done
    return 0
}

# Already inside the userns+netns: wait until pasta/slirp has attached,
# then exec bwrap so it inherits that netns.
if [[ "$in_netns" == true ]]; then
    if [[ -z "$ready" ]]; then
        mac_netns_error "MAC netns holder requires --ready"
        exit 1
    fi
    if ! read -r _ < "$ready"; then
        mac_netns_error "MAC netns holder lost its ready signal"
        exit 1
    fi
    wait_for_mac_interface || exit 1
    set +e
    run_with_netns_sysfs "$@"
    status=$?
    set -e
    exit "$status"
fi

if [[ -z "$unshare_bin" || ! -x "$unshare_bin" ]]; then
    mac_netns_error "unshare is not an executable file: ${unshare_bin:-<unset>}"
    exit 1
fi

trap cleanup_mac_backend EXIT INT TERM

hold_dir="$(mktemp -d --tmpdir mac-netns.XXXXXX)"
ready="$hold_dir/ready"
mkfifo -- "$ready"

# Holder is created first so pasta can attach to /proc/<pid>/ns/{user,net}
# from the host netns. The holder blocks on the fifo until pasta is started.
"$unshare_bin" --user --map-root-user --net -- \
    "$self" \
    --in-netns \
    --backend "$backend" \
    --mac "$mac" \
    --ready "$ready" \
    -- "$@" &
holder_pid="$!"

if [[ -z "$holder_pid" ]] || ! kill -0 "$holder_pid" 2>/dev/null; then
    holder_pid=""
    mac_netns_error "could not create the MAC identity user+net namespace"
    exit 1
fi
wait_for_holder_namespaces "$holder_pid" || exit 1

case "$backend" in
    pasta)
        if [[ -z "$pasta" || ! -x "$pasta" ]]; then
            mac_netns_error "pasta is not an executable file: ${pasta:-<unset>}"
            exit 1
        fi
        # pasta(1) is a symlink to passt; mode is selected by argv0.
        # realpath(/usr/bin/pasta) is /usr/bin/passt, which rejects --config-net.
        # --userns is required: --netns PATH alone implies --netns-only and
        # setns into a userns-owned netns fails with EPERM.
        # --foreground keeps this process so $! stays valid after we background.
        pasta_argv0_dir="$(mktemp -d --tmpdir pasta-argv0.XXXXXX)"
        ln -sfn -- "$pasta" "$pasta_argv0_dir/pasta"
        (
            set -- \
                --foreground \
                --config-net \
                --userns "/proc/${holder_pid}/ns/user" \
                --netns "/proc/${holder_pid}/ns/net" \
                --mac-addr "$mac" \
                --ns-mac-addr "$mac" \
                --ns-ifname "$guest_ifname"
            if [[ -n "$nic" ]]; then
                set -- "$@" --interface "$nic" --outbound-if4 "$nic"
            fi
            # Host resolv.conf is Tailscale MagicDNS (100.100.100.100).
            # That address is not reachable from pasta's netns, so XLN
            # "cannot download". Daily xln-fj pins 1.1.1.1 and the LAN
            # resolver instead.
            set -- "$@" --dns 1.1.1.1 --dns 192.168.1.1 --dhcp-dns
            # Pin the guest IPv4 Wine sees. Without this, pasta copies the
            # host template address (NAT), which is not the Firejail LAN IP.
            if [[ -n "$address" ]]; then
                set -- "$@" --address "$address"
            fi
            exec -a pasta "$pasta_argv0_dir/pasta" "$@"
        ) &
        backend_pid="$!"
        ;;
    slirp4netns)
        if [[ -z "$slirp" || ! -x "$slirp" ]]; then
            mac_netns_error "slirp4netns is not an executable file: ${slirp:-<unset>}"
            exit 1
        fi
        # Host-side slirp attaches to the holder PID. Targeting self from
        # inside an empty netns is the same local-only trap as pasta.
        "$slirp" --configure --disable-host-loopback --mac-addr "$mac" \
            "$holder_pid" tap0 &
        backend_pid="$!"
        ;;
    *)
        mac_netns_error "unknown MAC netns backend: $backend"
        exit 1
        ;;
esac

if [[ -z "$backend_pid" ]] || ! kill -0 "$backend_pid" 2>/dev/null; then
    backend_pid=""
    mac_netns_error "$backend failed to start"
    exit 1
fi

printf 'attached\n' > "$ready"

set +e
wait "$holder_pid"
status=$?
set -e
holder_pid=""
cleanup_mac_backend
trap - EXIT INT TERM
exit "$status"
