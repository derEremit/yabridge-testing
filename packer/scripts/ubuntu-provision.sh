#!/bin/bash
set -euo pipefail

# Ubuntu 24.04 Provisioning Script for Yabridge Testing

echo "=== Yabridge Test VM Provisioning (Ubuntu 24.04) ==="

# Update system
apt-get update
apt-get upgrade -y

# Install base development tools
apt-get install -y \
    build-essential \
    cmake \
    git \
    curl \
    wget \
    unzip \
    pkg-config \
    python3 \
    python3-pip \
    python3-venv

# Install audio/plugin dependencies
apt-get install -y \
    libasound2-dev \
    libjack-jackd2-dev \
    libpipewire-0.3-dev \
    libx11-dev \
    libxcb1-dev \
    libxcb-util-dev \
    libxcb-icccm4-dev \
    libxcb-keysyms1-dev \
    libxcb-randr0-dev \
    libxcb-xfixes0-dev \
    libfreetype6-dev \
    libgl1-mesa-dev \
    libglu1-mesa-dev

# Install Wine dependencies
dpkg --add-architecture i386
apt-get update
apt-get install -y \
    wine64 \
    wine32 \
    winetricks \
    cabextract

# Install Flatpak for DAW installation
apt-get install -y flatpak
flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo

# Install useful tools
apt-get install -y \
    htop \
    neovim \
    tmux \
    xdotool \
    xclip \
    wmctrl

# Install Python packages for test harness
pip3 install --break-system-packages \
    click \
    pydantic \
    httpx \
    rich

# Create yabridge directories
mkdir -p /opt/yabridge
mkdir -p /opt/test-plugins

# Set up audio group
usermod -aG audio yabridge || true

# Configure JACK/PipeWire
mkdir -p /etc/pipewire/pipewire.conf.d
cat > /etc/pipewire/pipewire.conf.d/yabridge.conf << 'EOF'
context.properties = {
    default.clock.rate = 48000
    default.clock.quantum = 256
    default.clock.min-quantum = 256
}
EOF

# Enable SSH
systemctl enable ssh

echo "=== Ubuntu provisioning complete ==="
