#!/bin/bash
# Setup yabridge (git master) + wine-staging (prebuilt) local test infrastructure
# No system install — everything under build/ and prefix/
set -euo pipefail

# The physical directory, not the name this invocation happened to use. A
# project kept behind a symlink is normal, and every path this script records —
# env.sh, test.sh, the component state — has to name the objects the files
# actually live in, because that is what later runs and the run manifest are
# about.
ROOT="$(cd -P -- "$(dirname -- "$0")" && pwd -P)"
BUILD="$ROOT/build"
PREFIX="$ROOT/prefix"
WINE_DIR="$BUILD/wine"
YABRIDGE_SRC="$BUILD/yabridge-src"
YABRIDGE_REPO_DEFAULT="https://github.com/robbert-vdh/yabridge.git"
YABRIDGE_OUT="$BUILD/yabridge"
HARNESS="$ROOT/test-harness"
HARNESS_VENV="$HARNESS/.venv"
ENV_FILE="$ROOT/env.sh"
STATE_FILE="$BUILD/component-state.env"

source "$ROOT/lib/component-state.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}[*]${NC} $1"; }
ok()    { echo -e "${GREEN}[✓]${NC} $1"; }
err()   { echo -e "${RED}[✗]${NC} $1"; }

WINE_CANDIDATE_ROOT=""
LOCKED_BUILD_IDENTITY=""

# Path strings stay equal across a rename-and-recreate, so only the device and
# inode of the object at $BUILD distinguish the locked build directory from an
# unlocked replacement.
build_identity_matches() {
    local current
    [[ -n "$LOCKED_BUILD_IDENTITY" && ! -L "$BUILD" ]] &&
        current="$(stat -c '%d:%i' -- "$BUILD" 2>/dev/null)" &&
        [[ "$current" == "$LOCKED_BUILD_IDENTITY" ]]
}

assert_locked_build_identity() {
    if ! build_identity_matches; then
        err "Build directory was replaced while setup held its lock: $BUILD"
        exit 1
    fi
}

is_owned_wine_candidate() {
    local candidate="$1"
    build_identity_matches &&
        [[ -n "$candidate" &&
            "$candidate" == "$BUILD"/.wine-candidate.* &&
            -d "$candidate" &&
            ! -L "$candidate" ]]
}

cleanup_current_wine_candidate() {
    local status=$?
    trap - EXIT INT TERM
    if is_owned_wine_candidate "$WINE_CANDIDATE_ROOT"; then
        rm -rf -- "$WINE_CANDIDATE_ROOT"
    fi
    return "$status"
}

cleanup_stale_wine_candidates() (
    local candidate marker candidate_path active_path
    shopt -s nullglob
    for candidate in "$BUILD"/.wine-candidate.*; do
        marker="$candidate/.yabridge-candidate"
        is_owned_wine_candidate "$candidate" || continue
        [[ -f "$marker" && ! -L "$marker" ]] || continue
        case "$(< "$marker")" in
            yabridge-wine-candidate-v1:pre-exchange | \
                yabridge-wine-candidate-v1:post-exchange) ;;
            *) continue ;;
        esac
        if [[ -e "$WINE_DIR" ]]; then
            candidate_path="$(realpath -e -- "$candidate")" || continue
            active_path="$(realpath -e -- "$WINE_DIR")" || continue
            [[ "$candidate_path" != "$active_path" ]] || continue
        fi
        rm -rf -- "$candidate"
    done
)

WINE_RELEASES_URL="https://github.com/Kron4ek/Wine-Builds/releases"
WINE_DOWNLOAD_URL="$WINE_RELEASES_URL/download"

# A Wine version names a release directory, a filename inside build/ and a URL
# path segment. Anything outside this shape could write the downloaded archive
# somewhere other than build/.
WINE_VERSION_PATTERN='^[A-Za-z0-9][A-Za-z0-9._+-]*$'

usage() {
    local status="${1:-1}"
    echo "Usage: $0 --wine-version VERSION --wine-sha256 SHA256 [--yabridge-branch BRANCH] [--yabridge-repo URL] [--yabridge-patch FILE]... [--no-wine] [--no-yabridge]"
    echo "  --wine-version       Wine version to download; required unless --no-wine"
    echo "  --wine-sha256        Expected SHA-256 of the Wine archive; required unless --no-wine"
    echo "  --yabridge-branch    Yabridge git branch/ref (default: master)"
    echo "  --yabridge-repo      Git repository to build from (default: $YABRIDGE_REPO_DEFAULT);"
    echo "                       an https://, ssh://, git@ URL or a local directory, e.g. a fork"
    echo "  --yabridge-patch     Patch file applied after checkout (git apply); repeatable, in order."
    echo "                       Only each patch's SHA-256 is recorded, never its path"
    echo "  --no-wine            Skip wine setup (use system wine)"
    echo "  --no-yabridge        Skip yabridge build"
    echo ""
    echo "Wine archives are only ever installed after their SHA-256 matches the"
    echo "digest you supplied. Choose a release at $WINE_RELEASES_URL and obtain"
    echo "its digest from a source you trust before installing it."
    exit "$status"
}

require_option_value() {
    local option="$1"
    local value="${2:-}"
    if [[ -z "$value" || "$value" == -* ]]; then
        err "$option requires a value"
        exit 2
    fi
}

WINE_VERSION=""
WINE_SHA256=""
WINE_VERSION_EXPLICIT=false
YABRIDGE_BRANCH="master"
YABRIDGE_REPO="$YABRIDGE_REPO_DEFAULT"
YABRIDGE_PATCHES=()
SKIP_WINE=false
SKIP_YABRIDGE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --wine-version)
            require_option_value "--wine-version" "${2:-}"
            WINE_VERSION="$2"
            WINE_VERSION_EXPLICIT=true
            shift 2
            ;;
        --wine-sha256)
            require_option_value "--wine-sha256" "${2:-}"
            WINE_SHA256="$2"
            shift 2
            ;;
        --yabridge-branch)
            require_option_value "--yabridge-branch" "${2:-}"
            YABRIDGE_BRANCH="$2"
            shift 2
            ;;
        --yabridge-repo)
            require_option_value "--yabridge-repo" "${2:-}"
            YABRIDGE_REPO="$2"
            shift 2
            ;;
        --yabridge-patch)
            require_option_value "--yabridge-patch" "${2:-}"
            YABRIDGE_PATCHES+=("$2")
            shift 2
            ;;
        --no-wine)         SKIP_WINE=true; shift ;;
        --no-yabridge)     SKIP_YABRIDGE=true; shift ;;
        -h|--help)         usage 0 ;;
        *)                 err "Unknown option: $1"; usage ;;
    esac
done

# The repository is handed to git verbatim, so it is held to a shape git will
# read as a remote and never as an option: a URL with a scheme git speaks, the
# scp-like git@ form, or a directory that already exists.
if [[ -d "$YABRIDGE_REPO" ]]; then
    YABRIDGE_REPO="$(realpath -- "$YABRIDGE_REPO")"
elif [[ ! "$YABRIDGE_REPO" =~ ^(https://|ssh://|git@)[A-Za-z0-9._:/@+-]+$ ]]; then
    err "--yabridge-repo must be an https://, ssh://, git@ URL or an existing directory: $YABRIDGE_REPO"
    exit 2
fi
# Patches are read before anything is fetched, and remembered by digest only:
# the path they came from is the operator's business, the bytes are the build's.
YABRIDGE_PATCH_DIGESTS=""
for patch in ${YABRIDGE_PATCHES[@]+"${YABRIDGE_PATCHES[@]}"}; do
    if [[ ! -f "$patch" || ! -r "$patch" ]]; then
        err "--yabridge-patch: not a readable file: $patch"
        exit 2
    fi
    digest="$(sha256sum -- "$patch" | cut -d' ' -f1)"
    YABRIDGE_PATCH_DIGESTS="${YABRIDGE_PATCH_DIGESTS:+$YABRIDGE_PATCH_DIGESTS+}$digest"
done
[[ -n "$YABRIDGE_PATCH_DIGESTS" ]] || YABRIDGE_PATCH_DIGESTS="none"

if [[ -n "$WINE_VERSION" && ! "$WINE_VERSION" =~ $WINE_VERSION_PATTERN ]]; then
    err "--wine-version must match $WINE_VERSION_PATTERN: $WINE_VERSION"
    exit 2
fi
# Installing Wine means executing bytes fetched over the network, so both the
# release and the digest that release is expected to have are required before
# anything is downloaded. Hashing whatever arrived and recording that hash
# would only prove the transfer was intact, which is a different question from
# whether these are the bytes anyone intended to run.
if [[ "$SKIP_WINE" == false && "$WINE_VERSION_EXPLICIT" == true &&
    -z "$WINE_SHA256" ]]; then
    err "--wine-sha256 is required with --wine-version"
    err "Obtain the digest for wine-$WINE_VERSION-staging-amd64.tar.xz from a"
    err "source you trust: $WINE_RELEASES_URL"
    exit 2
fi
if [[ "$SKIP_WINE" == false && "$WINE_VERSION_EXPLICIT" != true ]]; then
    err "--wine-version and --wine-sha256 are required to install Wine"
    err "Choose a release at $WINE_RELEASES_URL, obtain the SHA-256 of"
    err "wine-<version>-staging-amd64.tar.xz from a source you trust, then run:"
    err "  $0 --wine-version <version> --wine-sha256 <digest>"
    err "Pass --no-wine to skip Wine and keep using the system installation."
    exit 2
fi
if [[ -n "$WINE_SHA256" && ! "$WINE_SHA256" =~ ^[A-Fa-f0-9]{64}$ ]]; then
    err "--wine-sha256 must be a 64-character hexadecimal digest"
    exit 2
fi
WINE_SHA256="${WINE_SHA256,,}"

mkdir -p "$BUILD"
if [[ -L "$BUILD" || ! -d "$BUILD" ]]; then
    err "Build path must be a direct project directory: $BUILD"
    exit 1
fi
ROOT_CANONICAL="$(realpath -e -- "$ROOT")" || {
    err "Could not resolve project root for safe setup locking"
    exit 1
}
BUILD_CANONICAL="$(realpath -e -- "$BUILD")" || {
    err "Could not resolve build directory for safe setup locking"
    exit 1
}
if [[ "$BUILD_CANONICAL" != "$ROOT_CANONICAL/build" ]]; then
    err "Build directory resolves outside the project root: $BUILD"
    exit 1
fi
if ! command -v flock >/dev/null 2>&1 ||
    ! flock --version >/dev/null 2>&1; then
    err "flock is required for safe setup locking; install util-linux"
    exit 1
fi
if ! exec {SETUP_LOCK_FD}< "$BUILD"; then
    err "Could not open the build directory for safe setup locking"
    exit 1
fi
LOCKED_BUILD_CANONICAL="$(realpath -e -- "/proc/$$/fd/$SETUP_LOCK_FD")" || {
    err "Could not verify the build directory lock descriptor"
    exit 1
}
if [[ "$LOCKED_BUILD_CANONICAL" != "$BUILD_CANONICAL" ]]; then
    err "Build directory changed while acquiring the setup lock"
    exit 1
fi
if ! flock -n "$SETUP_LOCK_FD"; then
    err "Another setup is already running for $ROOT"
    exit 1
fi
CURRENT_BUILD_CANONICAL="$(realpath -e -- "$BUILD")" || {
    err "Build directory disappeared while acquiring the setup lock"
    exit 1
}
if [[ -L "$BUILD" ||
    "$CURRENT_BUILD_CANONICAL" != "$LOCKED_BUILD_CANONICAL" ]]; then
    err "Build directory changed while acquiring the setup lock"
    exit 1
fi
LOCKED_BUILD_IDENTITY="$(stat -L -c '%d:%i' -- \
    "/proc/$$/fd/$SETUP_LOCK_FD" 2>/dev/null)" || {
    err "Could not identify the locked build directory"
    exit 1
}
assert_locked_build_identity
mkdir -p "$PREFIX"
cleanup_stale_wine_candidates

STATE_WINE_VERSION="$(read_state WINE_VERSION "$STATE_FILE" || true)"
STATE_WINE_SHA256="$(read_state WINE_SHA256 "$STATE_FILE" || true)"
# Carried forward exactly as recorded. Only a successful digest comparison in
# this run may set it, so a state file written before this rule existed — or by
# hand — stays unproven no matter how many times setup runs afterwards.
STATE_WINE_SHA256_VERIFIED="$(read_state WINE_SHA256_VERIFIED "$STATE_FILE" ||
    true)"
STATE_YABRIDGE_REF="$(read_state YABRIDGE_REF "$STATE_FILE" || true)"
STATE_YABRIDGE_COMMIT="$(read_state YABRIDGE_COMMIT "$STATE_FILE" || true)"
# Older state files predate these two keys; absent means upstream, unpatched.
STATE_YABRIDGE_REPO="$(read_state YABRIDGE_REPO "$STATE_FILE" || printf '%s\n' "$YABRIDGE_REPO_DEFAULT")"
STATE_YABRIDGE_PATCHES="$(read_state YABRIDGE_PATCHES "$STATE_FILE" || printf 'none\n')"

# ── Install yabridge build dependencies ──────────────────────────────────────
info "Checking/installing build dependencies..."
DEPS=(
    base-devel meson ninja
    wine wine-staging      # provides winegcc for cross-compiling host exe
    libxcb lib32-libxcb    # X11 client library
    passt                  # pasta: daw-env.sh --mac fails closed without it
)

if command -v pacman &>/dev/null; then
    MISSING=()
    for pkg in "${DEPS[@]}"; do
        pacman -Qi "$pkg" &>/dev/null || MISSING+=("$pkg")
    done
    if [[ ${#MISSING[@]} -gt 0 ]]; then
        info "Installing: ${MISSING[*]}"
        sudo pacman -S --noconfirm "${MISSING[@]}"
    fi
else
    info "Skipping dep check — only pacman-based distros auto-install."
    info "Ensure you have: gcc >= 10, meson, ninja, wine + winegcc, libxcb-dev"
fi
ok "Build dependencies ready"

# ── Wine setup ────────────────────────────────────────────────────────────────
if [[ "$SKIP_WINE" == false ]]; then
    WINE_VER="$WINE_VERSION"
    WINE_URL="$WINE_DOWNLOAD_URL/${WINE_VER}/wine-${WINE_VER}-staging-amd64.tar.xz"

    # A cached install is reused only when the recorded state proves the same
    # release, the same expected digest, *and* that the digest was actually
    # compared. A record that merely repeats a hash somebody observed says
    # nothing about the bytes now sitting in build/wine, so it is treated as
    # no record at all and the archive is fetched and verified again.
    WINE_MATCHES=false
    if [[ -f "$WINE_DIR/bin/wine" ]] &&
        component_matches WINE_VERSION "$WINE_VER" "$STATE_FILE" &&
        component_matches WINE_SHA256 "$WINE_SHA256" "$STATE_FILE" &&
        component_matches WINE_SHA256_VERIFIED true "$STATE_FILE"; then
        WINE_MATCHES=true
    fi

    if [[ "$WINE_MATCHES" == true ]]; then
        info "Wine already present at $WINE_DIR"
        "$WINE_DIR/bin/wine" --version
    else
        info "Downloading wine-staging (Kron4ek prebuilt)..."
        assert_locked_build_identity
        TARBALL="$BUILD/wine-${WINE_VER}-staging-amd64.tar.xz"
        WINE_CANDIDATE_ROOT="$(mktemp -d "$BUILD/.wine-candidate.XXXXXX")"
        trap cleanup_current_wine_candidate EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
        printf 'yabridge-wine-candidate-v1:pre-exchange\n' \
            > "$WINE_CANDIDATE_ROOT/.yabridge-candidate"
        WINE_CANDIDATE_ARCHIVE="$WINE_CANDIDATE_ROOT/wine.tar.xz"
        info "Downloading $WINE_URL..."
        curl -fsSL -o "$WINE_CANDIDATE_ARCHIVE" "$WINE_URL" || {
            err "Download failed. Try a different version."
            err "See: https://github.com/Kron4ek/Wine-Builds/releases"
            exit 1
        }

        # The only path to an installed Wine. There is deliberately no branch
        # that computes a digest from the download and treats the result as
        # verification.
        if ! printf '%s  %s\n' "$WINE_SHA256" "$WINE_CANDIDATE_ARCHIVE" |
            sha256sum -c - >/dev/null; then
            err "Wine archive checksum mismatch"
            err "Expected $WINE_SHA256 for $WINE_URL"
            err "Nothing was installed and any existing Wine is untouched."
            exit 1
        fi
        VERIFIED_WINE_SHA256="$WINE_SHA256"

        if ! ARCHIVE_ENTRIES="$(tar -tf "$WINE_CANDIDATE_ARCHIVE")"; then
            err "Could not inspect Wine archive"
            exit 1
        fi
        while IFS= read -r ARCHIVE_ENTRY; do
            if [[ "$ARCHIVE_ENTRY" == /* ||
                "$ARCHIVE_ENTRY" =~ (^|/)\.\.(/|$) ]]; then
                err "Wine archive contains an unsafe path: $ARCHIVE_ENTRY"
                exit 1
            fi
        done <<< "$ARCHIVE_ENTRIES"

        if ! ARCHIVE_LINK_ERROR="$(python3 - "$WINE_CANDIDATE_ARCHIVE" 2>&1 <<'PY'
import pathlib
import sys
import tarfile

archive = sys.argv[1]

def is_unsafe(path):
    return path.startswith("/") or ".." in pathlib.PurePosixPath(path).parts

try:
    with tarfile.open(archive, "r:*") as contents:
        for member in contents:
            if (member.issym() or member.islnk()) and is_unsafe(member.linkname):
                print(
                    f"Wine archive contains an unsafe link target: "
                    f"{member.name} -> {member.linkname}"
                )
                raise SystemExit(1)
except (OSError, tarfile.TarError) as error:
    print(f"Could not inspect Wine archive links: {error}")
    raise SystemExit(1)
PY
        )"; then
            err "$ARCHIVE_LINK_ERROR"
            exit 1
        fi

        info "Extracting wine-staging $WINE_VER..."
        if ! tar -xaf "$WINE_CANDIDATE_ARCHIVE" -C "$WINE_CANDIDATE_ROOT/"; then
            err "Extraction failed"
            exit 1
        fi
        EXTRACTED_DIR="$(find "$WINE_CANDIDATE_ROOT" -mindepth 1 -maxdepth 1 \
            -type d -name '*staging*' -print -quit)"
        if [[ -z "$EXTRACTED_DIR" ]]; then
            err "Extraction failed — could not find wine directory"
            exit 1
        fi
        WINE_CANDIDATE_VALID=true
        EXTRACTED_CANONICAL="$(realpath -e -- "$EXTRACTED_DIR")" ||
            WINE_CANDIDATE_VALID=false
        # wine and wineserver must be regular executables. wineboot is a
        # relative symlink to wine in Kron4ek (and Wine) trees, including
        # 11.8 and 11.16; it still has to resolve to a regular file inside
        # the extracted candidate.
        for WINE_COMMAND in wine wineboot wineserver; do
            WINE_EXECUTABLE="$EXTRACTED_DIR/bin/$WINE_COMMAND"
            if [[ ! -f "$WINE_EXECUTABLE" ||
                ! -x "$WINE_EXECUTABLE" ]]; then
                WINE_CANDIDATE_VALID=false
                continue
            fi
            if [[ "$WINE_COMMAND" != wineboot && -L "$WINE_EXECUTABLE" ]]; then
                WINE_CANDIDATE_VALID=false
                continue
            fi
            WINE_EXECUTABLE_CANONICAL="$(realpath -e -- "$WINE_EXECUTABLE")" ||
                WINE_CANDIDATE_VALID=false
            if [[ "$WINE_CANDIDATE_VALID" == true &&
                "$WINE_EXECUTABLE_CANONICAL" != "$EXTRACTED_CANONICAL"/* ]]; then
                WINE_CANDIDATE_VALID=false
            fi
        done
        if [[ "$WINE_CANDIDATE_VALID" != true ]] ||
            ! "$EXTRACTED_DIR/bin/wine" --version >/dev/null 2>&1; then
            err "Extracted Wine candidate failed validation"
            exit 1
        fi

        assert_locked_build_identity
        mv -f "$WINE_CANDIDATE_ARCHIVE" "$TARBALL"
        if [[ -e "$WINE_DIR" ]]; then
            # Swapping a live build/wine is only offered atomically.
            if ! mv --help 2>/dev/null | grep -Fq -- '--exchange'; then
                err "GNU coreutils mv with --exchange support is required to replace $WINE_DIR"
                err "Update coreutils (>= 9.4), or move $WINE_DIR aside and rerun setup."
                exit 1
            fi
            if ! mv --exchange --no-copy -T "$EXTRACTED_DIR" "$WINE_DIR"; then
                err "Could not atomically activate Wine candidate"
                exit 1
            fi
        else
            # The candidate lives inside $BUILD, so this is a same-filesystem
            # rename either way; --no-copy (coreutils >= 9.2) only adds a
            # guard against silent cross-device copies and older coreutils
            # (Debian 12, Ubuntu 22.04) may not have it.
            MV_NO_COPY=(--no-copy)
            mv --help 2>/dev/null | grep -Fq -- '--no-copy' || MV_NO_COPY=()
            if ! mv ${MV_NO_COPY[@]+"${MV_NO_COPY[@]}"} -T "$EXTRACTED_DIR" "$WINE_DIR"; then
                err "Could not activate Wine candidate"
                exit 1
            fi
        fi
        printf 'yabridge-wine-candidate-v1:post-exchange\n' \
            > "$WINE_CANDIDATE_ROOT/.yabridge-candidate"
        rm -rf -- "$WINE_CANDIDATE_ROOT"
        WINE_CANDIDATE_ROOT=""
        trap - EXIT INT TERM
        ok "Wine-staging $WINE_VER extracted to $WINE_DIR"

        # Reached only after sha256sum -c accepted the archive and the
        # extracted candidate was activated, so this is the one place allowed
        # to claim the digest was verified.
        STATE_WINE_VERSION="$WINE_VER"
        STATE_WINE_SHA256="$VERIFIED_WINE_SHA256"
        STATE_WINE_SHA256_VERIFIED=true
    fi

    # Verify
    info "Wine version: $("$WINE_DIR/bin/wine" --version 2>/dev/null || echo 'check failed')"

    # Kron4ek archives ship no Wine Gecko/Mono add-ons. Without them, the
    # one-time upgrade of a real prefix throws modal mscoree "This application
    # could not be started" dialogs from inside the sandbox. The distro's wine
    # packages already carry copies the operator trusts via their package
    # manager, so expose those to the isolated build instead of downloading
    # anything. A version the build does not expect is simply ignored.
    for addon in gecko mono; do
        [[ -d "$WINE_DIR/share/wine" && ! -e "$WINE_DIR/share/wine/$addon" ]] || continue
        for candidate in /usr/share/wine /usr/local/share/wine; do
            if [[ -d "$candidate/$addon" ]]; then
                ln -sfn "$candidate/$addon" "$WINE_DIR/share/wine/$addon"
                info "Linked system Wine $addon from $candidate/$addon"
                continue 2
            fi
        done
        info "No system Wine $addon found; prefix upgrades may show" \
             "'application could not be started' dialogs (safe to dismiss)"
    done
fi

# ── Yabridge build ───────────────────────────────────────────────────────────
if [[ "$SKIP_YABRIDGE" == false ]]; then
    assert_locked_build_identity
    # Fetch and resolve the requested ref before deciding whether outputs match.
    if [[ -d "$YABRIDGE_SRC" ]]; then
        info "Updating yabridge source ($YABRIDGE_BRANCH from $YABRIDGE_REPO)..."
        if [[ "$STATE_YABRIDGE_REPO" != "$YABRIDGE_REPO" ]]; then
            git -C "$YABRIDGE_SRC" remote set-url origin "$YABRIDGE_REPO"
        fi
    else
        info "Cloning yabridge ($YABRIDGE_BRANCH from $YABRIDGE_REPO)..."
        git clone --no-checkout "$YABRIDGE_REPO" "$YABRIDGE_SRC"
    fi
    git -C "$YABRIDGE_SRC" fetch origin "$YABRIDGE_BRANCH"
    YABRIDGE_COMMIT="$(git -C "$YABRIDGE_SRC" rev-parse FETCH_HEAD)"
    git -C "$YABRIDGE_SRC" checkout --detach "$YABRIDGE_COMMIT"
    if [[ ${#YABRIDGE_PATCHES[@]} -gt 0 ]]; then
        # Start from the pristine commit so a previous run's patches never
        # stack, then apply this run's set in order. A patch that does not
        # apply stops setup before the build, with the previous outputs intact.
        git -C "$YABRIDGE_SRC" reset --hard "$YABRIDGE_COMMIT"
        for patch in "${YABRIDGE_PATCHES[@]}"; do
            info "Applying patch $(basename -- "$patch")..."
            if ! git -C "$YABRIDGE_SRC" apply --check "$patch"; then
                err "patch does not apply to $YABRIDGE_COMMIT: $patch"
                exit 1
            fi
            git -C "$YABRIDGE_SRC" apply "$patch"
        done
    fi

    YABRIDGE_MATCHES=false
    if [[ -f "$YABRIDGE_OUT/libyabridge-vst2.so" ]] &&
        [[ -f "$YABRIDGE_OUT/yabridge-host.exe" ]] &&
        component_matches YABRIDGE_REF "$YABRIDGE_BRANCH" "$STATE_FILE" &&
        component_matches YABRIDGE_COMMIT "$YABRIDGE_COMMIT" "$STATE_FILE" &&
        [[ "$STATE_YABRIDGE_REPO" == "$YABRIDGE_REPO" ]] &&
        [[ "$STATE_YABRIDGE_PATCHES" == "$YABRIDGE_PATCH_DIGESTS" ]]; then
        YABRIDGE_MATCHES=true
    fi

    if [[ "$YABRIDGE_MATCHES" == true ]]; then
        info "Yabridge already built at $YABRIDGE_OUT"
    else
        info "Building yabridge @ $YABRIDGE_COMMIT (patches: $YABRIDGE_PATCH_DIGESTS)..."

        # Build
        BUILD_DIR="$YABRIDGE_SRC/build"
        MESON_WIPE=()
        [[ -d "$BUILD_DIR" ]] && MESON_WIPE=(--wipe)
        meson setup "${MESON_WIPE[@]}" "$BUILD_DIR" "$YABRIDGE_SRC" --buildtype=release \
            --cross-file="$YABRIDGE_SRC/cross-wine.conf" \
            --unity=on --unity-size=1000 \
            --prefix="$YABRIDGE_OUT"

        ninja -C "$BUILD_DIR"

        # Collect build artifacts into $YABRIDGE_OUT
        info "Installing yabridge to $YABRIDGE_OUT..."
        rm -rf "$YABRIDGE_OUT"
        mkdir -p "$YABRIDGE_OUT"
        find "$BUILD_DIR" -maxdepth 3 -type f \
            \( -name 'libyabridge-*.so' -o -name 'yabridge-host.exe' -o -name 'yabridge-host.exe.so' \) \
            -exec cp -v {} "$YABRIDGE_OUT/" \;
        # Also copy yabridgectl if present
        find "$BUILD_DIR" -maxdepth 3 -type f -name 'yabridgectl' -exec cp -v {} "$YABRIDGE_OUT/" \; 2>/dev/null || true
        ok "Yabridge built and installed to $YABRIDGE_OUT"

        STATE_YABRIDGE_REF="$YABRIDGE_BRANCH"
        STATE_YABRIDGE_COMMIT="$YABRIDGE_COMMIT"
        STATE_YABRIDGE_REPO="$YABRIDGE_REPO"
        STATE_YABRIDGE_PATCHES="$YABRIDGE_PATCH_DIGESTS"
    fi

    # Show built files
    ls -lh "$YABRIDGE_OUT/"
fi

assert_locked_build_identity
write_state "$STATE_FILE" \
    "WINE_VERSION=$STATE_WINE_VERSION" \
    "WINE_SHA256=$STATE_WINE_SHA256" \
    "WINE_SHA256_VERIFIED=$STATE_WINE_SHA256_VERIFIED" \
    "YABRIDGE_REF=$STATE_YABRIDGE_REF" \
    "YABRIDGE_COMMIT=$STATE_YABRIDGE_COMMIT" \
    "YABRIDGE_REPO=$STATE_YABRIDGE_REPO" \
    "YABRIDGE_PATCHES=$STATE_YABRIDGE_PATCHES"

# ── Install test harness ─────────────────────────────────────────────────────
if [[ ! -f "$HARNESS/pyproject.toml" ]]; then
    err "Test harness project not found at $HARNESS"
    exit 1
fi
info "Installing test harness into $HARNESS_VENV..."
python3 -m venv "$HARNESS_VENV"
"$HARNESS_VENV/bin/python" -m pip install \
    --disable-pip-version-check -e "$HARNESS"
ok "Test harness installed"

# ── Generate env.sh ──────────────────────────────────────────────────────────
# Scaffold the pinned network identity daw-env.sh --mac and the XLN docs
# reference. Detected from the default route so the values are real for this
# host; the operator pins them the moment a vendor authorizes against them.
# Never overwritten: an existing file may already carry an authorized identity.
if [[ ! -e run-state/identity.env ]]; then
    ID_NIC="$(ip -o route show default 2>/dev/null |
        awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}')"
    if [[ -n "$ID_NIC" && -r "/sys/class/net/$ID_NIC/address" ]]; then
        ID_MAC="$(cat "/sys/class/net/$ID_NIC/address")"
        ID_ADDR="$(ip -o -4 addr show dev "$ID_NIC" 2>/dev/null |
            awk 'NR==1{sub(/\/.*/,"",$4); print $4}')"
        mkdir -p run-state
        cat > run-state/identity.env <<IDENTITY
# Pinned network identity for daw-env.sh --mac / --nic / --address (vendor
# license checks such as the XLN Computer ID). Detected from this host's
# default route by setup.sh. Once a vendor authorizes this identity, keep
# these values stable forever and never regenerate this file.
XLN_MAC=$ID_MAC
XLN_NIC=$ID_NIC
XLN_ADDR=$ID_ADDR
IDENTITY
        info "Wrote identity template run-state/identity.env ($ID_NIC $ID_MAC)"
    fi
fi

info "Generating $ENV_FILE..."
cat > "$ENV_FILE" << ENVEOF
# Yabridge + Wine-Staging isolated test environment
#
# WARNING: sourcing this redirects WINELOADER to wine 11.8 staging and sets
# WINEPREFIX to the isolated prefix/ (no real plugins). Don't launch your DAW
# after sourcing this directly — use the wrappers instead:
#
#   ./test.sh info              # collect env info (test harness only)
#   ./test.sh probe             # run mouse tests
#   ./daw-env.sh reaper         # launch DAW against a COW clone of your prefix
#   ./daw-env.sh bitwig-studio
#
# ./daw-env.sh reflink-clones your real Wine prefix into prefix-copy/ and
# points WINEPREFIX there — the launcher mounts your production prefix
# read-only and writes go to the clone.
# No file swaps, no backups, no restore. With ./daw-env.sh, production plugin
# roots and your yabridge install are mounted read-only.
#
# To use the custom wine directly without affecting your DAW:
#   source env.sh && yabridge-wine --version

export YABRIDGE_TEST_ROOT="$ROOT"
export YABRIDGE_BUILD="$BUILD"
export YABRIDGE_WINE="$WINE_DIR"
export YABRIDGE_BIN="$YABRIDGE_OUT"

# Wine overrides
export WINELOADER="$WINE_DIR/bin/wine"
export WINESERVER="$WINE_DIR/bin/wineserver"
export WINEDLLPATH="$WINE_DIR/lib/wine:$WINE_DIR/lib64/wine"
export WINEPREFIX="$PREFIX"

# PATH — add custom wine and yabridge
export PATH="$WINE_DIR/bin:$YABRIDGE_OUT:\${PATH:-}"

# Library path for custom wine shared libs
export LD_LIBRARY_PATH="$WINE_DIR/lib:$WINE_DIR/lib64:\${LD_LIBRARY_PATH:-}"

# Let yabridge know where to find its .exe files
export YABRIDGE_HOST_EXE="$YABRIDGE_OUT/yabridge-host.exe"

# Test harness picks these up
export YABRIDGE_TEST_WINE="$WINE_DIR/bin/wine"
export YABRIDGE_TEST_YABRIDGE="$YABRIDGE_OUT"

# WINEDEBUG is deliberately left alone. Silencing Wine here would hide the
# warnings and crash traces of every later run, including plugin failures the
# whole prefix exists to investigate. Pass --quiet-wine to ./daw-env.sh, or
# export WINEDEBUG yourself, when you want a quiet log.

# Aliases for convenience
alias yabridge-wine='env WINELOADER="$WINE_DIR/bin/wine" WINEPREFIX="\$WINEPREFIX" "$WINE_DIR/bin/wine"'
alias yabridge-winecfg='env WINELOADER="$WINE_DIR/bin/wine" WINEPREFIX="\$WINEPREFIX" "$WINE_DIR/bin/wine" winecfg'
alias yabridge-winetricks='env WINELOADER="$WINE_DIR/bin/wine" WINEPREFIX="\$WINEPREFIX" winetricks'

echo "Yabridge test environment ready:"
echo "  Wine:     \$("$WINE_DIR/bin/wine" --version 2>/dev/null)"
echo "  Yabridge: \$YABRIDGE_BIN"
echo "  Prefix:   \$WINEPREFIX"
echo ""
echo "Commands available:"
echo "  yabridge-test info     — collect system info"
echo "  yabridge-test probe     — run mouse coordinate tests"
echo "  yabridge-wine winecfg  — configure wine prefix"
echo "  yabridge-wine --version"
ENVEOF

chmod +x "$ENV_FILE"

# If yabridge was built, also write a test helper
cat > "$ROOT/test.sh" << 'TESTEOF'
#!/bin/bash
# Run yabridge test harness with isolated wine + yabridge
set -euo pipefail
ROOT="$(cd -P -- "$(dirname -- "$0")" && pwd -P)"
HARNESS="$ROOT/test-harness"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    cat <<'EOF'
Usage: ./test.sh <yabridge-test-args>

Runs the staging-installed yabridge-test CLI with env.sh loaded.

  ./test.sh info
  ./test.sh probe
  ./test.sh suite

EOF
    exit 0
fi

if [[ ! -f "$ROOT/env.sh" ]]; then
    echo "error: environment is not configured; run ./setup.sh first" >&2
    exit 1
fi
if [[ ! -x "$HARNESS/.venv/bin/yabridge-test" ]]; then
    echo "error: test harness is not installed; run ./setup.sh first" >&2
    exit 1
fi
# env.sh is generated by setup and is not present at lint time.
# shellcheck source=/dev/null
source "$ROOT/env.sh" >&2   # banner to stderr so --dry-run stdout stays pure JSON
exec "$HARNESS/.venv/bin/yabridge-test" "$@"
TESTEOF
chmod +x "$ROOT/test.sh"

# ── Initialize WINEPREFIX ────────────────────────────────────────────────────
if [[ ! -f "$PREFIX/system.reg" ]]; then
    info "Initializing WINEPREFIX at $PREFIX..."
    WINELOADER="$WINE_DIR/bin/wine" WINESERVER="$WINE_DIR/bin/wineserver" \
        WINEPREFIX="$PREFIX" WINEDEBUG=-all \
        "$WINE_DIR/bin/wineboot" -u 2>/dev/null || true
    # Sometimes wineboot needs more time
    sleep 2
    if [[ -f "$PREFIX/system.reg" ]]; then
        ok "WINEPREFIX initialized"
    else
        info "WINEPREFIX not fully created yet. Run 'source env.sh && wine winecfg' to finish setup."
    fi
else
    info "WINEPREFIX already exists at $PREFIX"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Setup complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "  Run the test harness (isolated wine + yabridge):"
echo "    ./test.sh info"
echo "    ./test.sh probe"
echo ""
echo "  Run a DAW with wine 11.8 + yabridge master:"
echo "    ./daw-env.sh reaper"
echo "    ./daw-env.sh bitwig-studio"
echo "    (clones your real prefix copy-on-write; the sandbox mounts production paths read-only)"
echo ""
echo "  Manage the isolated test prefix:"
echo "    source env.sh && yabridge-wine winecfg"
echo ""
echo "  Advanced — source env.sh directly (sets WINEPREFIX=prefix/):"
echo "    NOTE: don't launch your DAW this way. Use ./daw-env.sh instead."
echo ""
