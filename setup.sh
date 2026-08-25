#!/bin/bash
# Setup yabridge (git master) + wine-staging (prebuilt) local test infrastructure
# No system install — everything under build/ and prefix/
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
PREFIX="$ROOT/prefix"
WINE_DIR="$BUILD/wine"
YABRIDGE_SRC="$BUILD/yabridge-src"
YABRIDGE_OUT="$BUILD/yabridge"
ENV_FILE="$ROOT/env.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}[*]${NC} $1"; }
ok()    { echo -e "${GREEN}[✓]${NC} $1"; }
err()   { echo -e "${RED}[✗]${NC} $1"; }

usage() {
    echo "Usage: $0 [--wine-version VERSION] [--yabridge-branch BRANCH] [--no-wine] [--no-yabridge]"
    echo "  --wine-version       Wine version to download (default: latest-staging)"
    echo "  --yabridge-branch    Yabridge git branch/ref (default: master)"
    echo "  --no-wine            Skip wine setup (use system wine)"
    echo "  --no-yabridge        Skip yabridge build"
    exit 1
}

WINE_VERSION="latest-staging"
YABRIDGE_BRANCH="master"
SKIP_WINE=false
SKIP_YABRIDGE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --wine-version)    WINE_VERSION="$2"; shift 2 ;;
        --yabridge-branch) YABRIDGE_BRANCH="$2"; shift 2 ;;
        --no-wine)         SKIP_WINE=true; shift ;;
        --no-yabridge)     SKIP_YABRIDGE=true; shift ;;
        -h|--help)         usage ;;
        *)                 err "Unknown option: $1"; usage ;;
    esac
done

mkdir -p "$BUILD" "$PREFIX"

# ── Install yabridge build dependencies ──────────────────────────────────────
info "Checking/installing build dependencies..."
DEPS=(
    base-devel meson ninja
    wine wine-staging      # provides winegcc for cross-compiling host exe
    libxcb lib32-libxcb    # X11 client library
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
    if [[ -f "$WINE_DIR/bin/wine" ]]; then
        info "Wine already present at $WINE_DIR"
        "$WINE_DIR/bin/wine" --version
    else
        info "Downloading wine-staging (Kron4ek prebuilt)..."
        mkdir -p "$WINE_DIR"

        # Fetch latest release info from Kron4ek/Wine-Builds
        if [[ "$WINE_VERSION" == "latest-staging" ]]; then
            info "Determining latest staging version..."
            API="https://api.github.com/repos/Kron4ek/Wine-Builds/releases"
            LATEST=$(curl -fsSL "$API" | python3 -c "
import json, sys
releases = json.load(sys.stdin)
for r in releases:
    for a in r.get('assets', []):
        n = a['name']
        # Match: wine-11.8-staging-amd64.tar.xz (not wow64, not tkg, not x86)
        if ('staging' in n and n.endswith('amd64.tar.xz')
                and 'wow64' not in n and 'tkg' not in n):
            # Extract version: wine-11.8-staging-amd64.tar.xz -> 11.8
            ver = n.replace('wine-', '').replace('-staging-amd64.tar.xz', '')
            print(f'{ver}|{a[\"browser_download_url\"]}')
            break
    else:
        continue
    break
")
            if [[ -z "$LATEST" ]]; then
                err "Could not determine latest wine-staging version"
                err "Check https://github.com/Kron4ek/Wine-Builds/releases"
                exit 1
            fi
            WINE_VER="${LATEST%%|*}"
            WINE_URL="${LATEST##*|}"
            info "Latest staging version: $WINE_VER"
        else
            WINE_VER="$WINE_VERSION"
            WINE_URL="https://github.com/Kron4ek/Wine-Builds/releases/download/${WINE_VER}/wine-${WINE_VER}-staging-amd64.tar.xz"
        fi

        TARBALL="$BUILD/wine-${WINE_VER}-staging-amd64.tar.xz"
        if [[ ! -f "$TARBALL" ]]; then
            info "Downloading $WINE_URL..."
            curl -fsSL -o "$TARBALL" "$WINE_URL" || {
                err "Download failed. Try a different version."
                err "See: https://github.com/Kron4ek/Wine-Builds/releases"
                exit 1
            }
        fi

        info "Extracting wine-staging $WINE_VER..."
        tar -xaf "$TARBALL" -C "$BUILD/"
        # Extracts to build/wine-<ver>-staging-amd64/ — rename to build/wine
        rm -rf "$WINE_DIR"  # remove empty dir created by mkdir -p
        EXTRACTED_DIR=$(find "$BUILD" -maxdepth 1 -type d -name '*staging*' | head -1)
        if [[ -z "$EXTRACTED_DIR" ]]; then
            err "Extraction failed — could not find wine directory"
            exit 1
        fi
        mv "$EXTRACTED_DIR" "$WINE_DIR"
        ok "Wine-staging $WINE_VER extracted to $WINE_DIR"
    fi

    # Verify
    info "Wine version: $("$WINE_DIR/bin/wine" --version 2>/dev/null || echo 'check failed')"
fi

# ── Yabridge build ───────────────────────────────────────────────────────────
if [[ "$SKIP_YABRIDGE" == false ]]; then
    if [[ -f "$YABRIDGE_OUT/libyabridge-vst2.so" ]] && [[ -f "$YABRIDGE_OUT/yabridge-host.exe" ]]; then
        info "Yabridge already built at $YABRIDGE_OUT"
    else
        # Clone
        if [[ -d "$YABRIDGE_SRC" ]]; then
            info "Updating yabridge source ($YABRIDGE_BRANCH)..."
            git -C "$YABRIDGE_SRC" fetch origin
            git -C "$YABRIDGE_SRC" checkout "$YABRIDGE_BRANCH"
            git -C "$YABRIDGE_SRC" pull --ff-only
        else
            info "Cloning yabridge ($YABRIDGE_BRANCH)..."
            git clone --branch "$YABRIDGE_BRANCH" --depth 1 \
                https://github.com/robbert-vdh/yabridge.git "$YABRIDGE_SRC"
        fi

        # Get commit info
        YABRIDGE_COMMIT=$(git -C "$YABRIDGE_SRC" rev-parse --short HEAD)
        info "Building yabridge @ $YABRIDGE_COMMIT..."

        # Build
        BUILD_DIR="$YABRIDGE_SRC/build"
        meson setup "$YABRIDGE_SRC" "$BUILD_DIR" --buildtype=release \
            --cross-file="$YABRIDGE_SRC/cross-wine.conf" \
            --unity=on --unity-size=1000 \
            --prefix="$YABRIDGE_OUT"

        ninja -C "$BUILD_DIR"

        # Collect build artifacts into $YABRIDGE_OUT
        info "Installing yabridge to $YABRIDGE_OUT..."
        mkdir -p "$YABRIDGE_OUT"
        find "$BUILD_DIR" -maxdepth 3 -type f \
            \( -name 'libyabridge-*.so' -o -name 'yabridge-host.exe' -o -name 'yabridge-host.exe.so' \) \
            -exec cp -v {} "$YABRIDGE_OUT/" \;
        # Also copy yabridgectl if present
        find "$BUILD_DIR" -maxdepth 3 -type f -name 'yabridgectl' -exec cp -v {} "$YABRIDGE_OUT/" \; 2>/dev/null || true
        ok "Yabridge built and installed to $YABRIDGE_OUT"
    fi

    # Show built files
    ls -lh "$YABRIDGE_OUT/"
fi

# ── Generate env.sh ──────────────────────────────────────────────────────────
info "Generating $ENV_FILE..."
cat > "$ENV_FILE" << ENVEOF
# Yabridge + Wine-Staging isolated test environment
#
# WARNING: sourcing this redirects WINELOADER to wine 11.8 staging and sets
# WINEPREFIX to the isolated prefix/ (no real plugins). Don't launch your DAW
# after sourcing this directly — use the wrappers instead:
#
#   ./test.sh info              # collect env info (test harness only)
#   ./test.sh validate          # run mouse tests
#   ./daw-env.sh reaper         # launch DAW against a COW clone of your prefix
#   ./daw-env.sh bitwig-studio
#
# ./daw-env.sh reflink-clones your real Wine prefix into prefix-copy/ and
# points WINEPREFIX there — your original prefix is only read, never written.
# No file swaps, no backups, no restore. Your VST dirs and yabridge install
# are never modified either.
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

# Prevent WINEDEBUG spam during tests
export WINEDEBUG=-all

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
echo "  yabridge-test validate  — run mouse coordinate tests"
echo "  yabridge-wine winecfg  — configure wine prefix"
echo "  yabridge-wine --version"
ENVEOF

chmod +x "$ENV_FILE"

# If yabridge was built, also write a test helper
cat > "$ROOT/test.sh" << 'TESTEOF'
#!/bin/bash
# Run yabridge test harness with isolated wine + yabridge
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$ROOT/env.sh"
HARNESS="$ROOT/yabridge-test-infra/test-harness"
if [[ -f "$HARNESS/.venv/bin/activate" ]]; then
    source "$HARNESS/.venv/bin/activate"
fi
exec yabridge-test "$@"
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
echo "    ./test.sh validate"
echo ""
echo "  Run a DAW with wine 11.8 + yabridge master:"
echo "    ./daw-env.sh reaper"
echo "    ./daw-env.sh bitwig-studio"
echo "    (clones your real prefix copy-on-write — originals never touched)"
echo ""
echo "  Manage the isolated test prefix:"
echo "    source env.sh && yabridge-wine winecfg"
echo ""
echo "  Advanced — source env.sh directly (sets WINEPREFIX=prefix/):"
echo "    NOTE: don't launch your DAW this way. Use ./daw-env.sh instead."
echo ""
