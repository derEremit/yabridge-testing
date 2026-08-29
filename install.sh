#!/bin/bash
# Yabridge Test Harness Installer
# Usage: curl -fsSL https://raw.githubusercontent.com/derEremit/yabridge-testing/main/install.sh | bash

set -e

REPO_URL="https://github.com/derEremit/yabridge-testing"
INSTALL_DIR="${YABRIDGE_TEST_HOME:-$HOME/.yabridge-test}"

echo "=== Yabridge Test Harness Installer ==="
echo ""

# Check dependencies
check_deps() {
    local missing=()

    command -v python3 >/dev/null 2>&1 || missing+=("python3")
    command -v git >/dev/null 2>&1 || missing+=("git")
    command -v xdotool >/dev/null 2>&1 || missing+=("xdotool")

    if [ ${#missing[@]} -ne 0 ]; then
        echo "Missing dependencies: ${missing[*]}"
        echo ""
        echo "Install with:"
        echo "  Arch:   sudo pacman -S ${missing[*]}"
        echo "  Ubuntu: sudo apt install ${missing[*]}"
        echo "  Fedora: sudo dnf install ${missing[*]}"
        exit 1
    fi
}

check_deps

# Create install directory
echo "Installing to: $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"

# Clone or update repository
if [ -d "$INSTALL_DIR/repo" ]; then
    echo "Updating existing installation..."
    cd "$INSTALL_DIR/repo"
    git pull --quiet
else
    echo "Cloning repository..."
    git clone --depth 1 "$REPO_URL" "$INSTALL_DIR/repo" 2>/dev/null || {
        # Fallback: download tarball if git clone fails
        echo "Git clone failed, downloading tarball..."
        curl -fsSL "$REPO_URL/archive/main.tar.gz" | tar -xz -C "$INSTALL_DIR"
        mv "$INSTALL_DIR/yabridge-testing-main" "$INSTALL_DIR/repo"
    }
fi

# Set up virtual environment
echo "Setting up Python environment..."
cd "$INSTALL_DIR/repo/test-harness"

if [ ! -d ".venv" ]; then
    python3 -m venv .venv
fi

source .venv/bin/activate
pip install -q -e .

# Create wrapper script
cat > "$INSTALL_DIR/yabridge-test" << 'EOF'
#!/bin/bash
INSTALL_DIR="${YABRIDGE_TEST_HOME:-$HOME/.yabridge-test}"
source "$INSTALL_DIR/repo/test-harness/.venv/bin/activate"
exec yabridge-test "$@"
EOF
chmod +x "$INSTALL_DIR/yabridge-test"

# Add to PATH instructions
echo ""
echo "=== Installation complete ==="
echo ""
echo "Add to your PATH by adding this to ~/.bashrc or ~/.zshrc:"
echo ""
echo "  export PATH=\"$INSTALL_DIR:\$PATH\""
echo ""
echo "Then run:"
echo "  source ~/.bashrc"
echo "  yabridge-test info"
echo ""
echo "Or run directly:"
echo "  $INSTALL_DIR/yabridge-test info"
echo ""
