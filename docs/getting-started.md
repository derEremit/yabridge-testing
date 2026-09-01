# Getting Started

This guide will help you set up the yabridge testing infrastructure.

## System Dependencies

### Arch Linux / Garuda / Manjaro

```bash
# Core dependencies for test harness
sudo pacman -S python python-pip xdotool xorg-xrandr wmctrl

# For building VMs with Packer
sudo pacman -S packer qemu-full libvirt virt-manager edk2-ovmf

# For Ansible provisioning
sudo pacman -S ansible

# Optional: for local development
sudo pacman -S python-virtualenv
```

### Ubuntu / Debian

```bash
# Build dependencies for setup.sh (yabridge + probe). setup.sh only
# auto-installs on pacman distros; install these yourself first.
sudo apt install build-essential meson ninja-build wine wine64-tools \
    libxcb1-dev mingw-w64
# 32-bit chainloaders additionally need the i386 dev packages:
#   sudo dpkg --add-architecture i386 && sudo apt update
#   sudo apt install gcc-multilib libxcb1-dev:i386
# daw-env.sh --mac needs user-mode networking:
sudo apt install passt

# Core dependencies for test harness
sudo apt install python3 python3-pip python3-venv xdotool x11-xserver-utils wmctrl

# For building VMs with Packer
sudo apt install packer qemu-kvm libvirt-daemon-system virt-manager ovmf

# For Ansible provisioning
sudo apt install ansible
```

First-time `setup.sh` works with any coreutils. Replacing an existing
`build/wine` in place (moving to another Wine version) and `daw-env.sh`'s
`--fresh`/bridge refresh need `mv --exchange` from coreutils >= 9.4
(Ubuntu 24.04+, Debian 13+); on older releases move `build/wine` aside
and rerun instead.

### Fedora

```bash
# Core dependencies for test harness
sudo dnf install python3 python3-pip xdotool xrandr wmctrl

# For building VMs with Packer
sudo dnf install packer qemu-kvm libvirt virt-manager edk2-ovmf

# For Ansible provisioning
sudo dnf install ansible
```

### What Each Package Does

| Package | Purpose |
|---------|---------|
| `python`, `python-pip` | Run test harness CLI |
| `xdotool` | Mouse coordinate testing (simulates clicks) |
| `xorg-xrandr` / `x11-xserver-utils` | Monitor detection |
| `wmctrl` | Window management for tests |
| `packer` | Build reproducible VM images |
| `qemu-full` / `qemu-kvm` | Run virtual machines |
| `libvirt`, `virt-manager` | VM management GUI |
| `edk2-ovmf` / `ovmf` | UEFI firmware for VMs |
| `ansible` | Automated VM provisioning |

## Prerequisites

- Linux system with X11 or Wayland
- Python 3.10+
- Wine 9.x or 10.x
- yabridge installed

## Quick Start: Running Tests

The fastest way to contribute test results is using the test harness CLI.

### 1. Install the Test Harness

```bash
cd test-harness

# Create and activate virtual environment
python -m venv .venv
source .venv/bin/activate

# Install the package
pip install -e .
```

### 2. Verify Your Environment

```bash
yabridge-test info
```

This will display your system configuration:
- Distribution and kernel
- Desktop environment
- Wine version
- yabridge version
- Display settings

### 3. Run Tests

```bash
# Run mouse coordinate validation
yabridge-test validate

# Test a specific plugin
yabridge-test plugin /path/to/plugin.vst3

# Run full test suite
yabridge-test suite
```

### 4. Submit a draft

Every submit path POSTs a sanitized draft and prints an edit URL. Nothing is
published until you open that URL, fill notes / plugins / verdict, and click
Publish. **Save** keeps the report private and the link usable so you can come
back and edit; **Publish** makes it public and retires the link. Home paths,
prefix paths, and plugin paths are stripped before HTTP.

Until the results site with the Save/Publish editor is deployed, the live
site publishes on the first submit of the form and the link then stops
working — fill everything in before you submit.

```bash
# Isolated-DAW session (environment + run-manifest scalars, no probe rows)
./test.sh submit --session
# or: yabridge-test submit --session --notes "optional local notes"

# Probe or suite, then the same edit URL
./test.sh probe --submit
./test.sh suite --submit

# Or submit a previously saved report file
yabridge-test submit --file results.json
```

`--dry-run` prints the sanitized JSON and does not POST. Session-specific
operator notes stay in gitignored `run-state/` and are not this repository.

## Building VM Images

For reproducible testing environments, you can build VM images with Packer.

### Prerequisites

- Packer 1.9+
- QEMU/KVM
- libvirt (optional)

### Building Ubuntu Image

```bash
cd packer

# Initialize Packer plugins
packer init ubuntu-2404-gnome.pkr.hcl

# Build the image
packer build ubuntu-2404-gnome.pkr.hcl
```

### Building Arch Linux Image

```bash
cd packer
packer init arch-kde-plasma.pkr.hcl
packer build arch-kde-plasma.pkr.hcl
```

### Running the VM

```bash
# With virt-manager (recommended)
virt-install --import --name yabridge-test \
  --disk output-ubuntu-2404-gnome/ubuntu-2404-gnome \
  --memory 8192 --vcpus 4 --os-variant ubuntu24.04

# Or with QEMU directly
qemu-system-x86_64 -enable-kvm \
  -m 8G -smp 4 \
  -drive file=output-ubuntu-2404-gnome/ubuntu-2404-gnome,format=qcow2 \
  -display gtk,gl=on
```

## Provisioning with Ansible

After booting a VM, use Ansible to install Wine, yabridge, and test plugins.

### Configure Inventory

Edit `ansible/inventory/hosts.yml` with your VM's IP address:

```yaml
all:
  children:
    vms:
      hosts:
        test-vm:
          ansible_host: 192.168.122.10
          ansible_user: yabridge
```

### Run Playbooks

```bash
cd ansible

# Base provisioning
ansible-playbook playbooks/provision-base.yml

# Install Wine
ansible-playbook playbooks/install-wine.yml

# Build yabridge from source with Meson and cross-wine.conf
ansible-playbook playbooks/build-yabridge.yml

# Install DAWs
ansible-playbook playbooks/install-daws.yml

# Install test plugins
ansible-playbook playbooks/install-test-plugins.yml
```

Vital 1.5.5, Dexed 0.9.7, OB-Xd 2.10, and REAPER 7.24 are version-pinned by URL only; the vendors do not publish a digest for those exact installer URLs.

## Next Steps

- Read [test-protocol.md](test-protocol.md) for the standard test procedure
