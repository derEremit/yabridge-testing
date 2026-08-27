#!/bin/bash
set -euo pipefail

# Arch Linux Provisioning Script for Yabridge Testing

echo "=== Yabridge Test VM Provisioning (Arch Linux) ==="

# Update system
pacman -Syu --noconfirm

# Install base development tools
pacman -S --noconfirm \
    base-devel \
    cmake \
    git \
    curl \
    wget \
    unzip \
    pkgconf \
    python \
    python-pip \
    python-pipx

# Install audio/plugin dependencies
pacman -S --noconfirm \
    alsa-lib \
    jack2 \
    pipewire \
    pipewire-jack \
    pipewire-alsa \
    pipewire-pulse \
    wireplumber \
    libx11 \
    libxcb \
    xcb-util \
    xcb-util-wm \
    xcb-util-keysyms \
    freetype2 \
    mesa \
    glu

# Install Wine
pacman -S --noconfirm \
    wine \
    wine-mono \
    wine-gecko \
    winetricks \
    lib32-gnutls \
    lib32-sdl2 \
    lib32-libpulse

# Install Flatpak for DAW installation
pacman -S --noconfirm flatpak
flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo

# Install AUR helper (yay)
if ! command -v yay &> /dev/null; then
    cd /tmp
    git clone https://aur.archlinux.org/yay-bin.git
    cd yay-bin
    makepkg -si --noconfirm
    cd /
    rm -rf /tmp/yay-bin
fi

# Install useful tools
pacman -S --noconfirm \
    htop \
    neovim \
    tmux \
    xdotool \
    xclip \
    wmctrl \
    wl-clipboard

# Install Python packages for test harness
pipx install click
pipx install pydantic
pipx install httpx
pipx install rich

# Create yabridge directories
mkdir -p /opt/yabridge
mkdir -p /opt/test-plugins

# Configure PipeWire
mkdir -p /etc/pipewire/pipewire.conf.d
cat > /etc/pipewire/pipewire.conf.d/yabridge.conf << 'EOF'
context.properties = {
    default.clock.rate = 48000
    default.clock.quantum = 256
    default.clock.min-quantum = 256
}
EOF

# Enable SSH
systemctl enable sshd

echo "=== Arch provisioning complete ==="
