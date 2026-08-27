packer {
  required_plugins {
    qemu = {
      version = "1.1.6"
      source  = "github.com/hashicorp/qemu"
    }
  }
}

variable "vm_name" {
  type    = string
  default = "arch-kde-plasma"
}

variable "cpus" {
  type    = number
  default = 4
}

variable "memory" {
  type    = number
  default = 8192
}

variable "disk_size" {
  type    = string
  default = "50G"
}

variable "ssh_username" {
  type    = string
  default = "yabridge"
}

variable "ssh_password" {
  type    = string
  default = "yabridge"
  sensitive = true
}

variable "ssh_timeout" {
  type    = string
  default = "45m"
}

variable "headless" {
  type    = bool
  default = false
}

variable "iso_url" {
  type    = string
  default = "https://geo.mirror.pkgbuild.com/iso/2026.08.01/archlinux-x86_64.iso"
}

variable "iso_checksum" {
  type    = string
  default = "sha256:4e82dced1c4fd3e498b22a853f8db2a4d262d32b97e7e07d97390d9e425ffe5e"
}

source "qemu" "arch-kde-plasma" {
  vm_name          = var.vm_name
  iso_url          = var.iso_url
  iso_checksum     = var.iso_checksum
  output_directory = "output-${var.vm_name}"

  cpus        = var.cpus
  memory      = var.memory
  disk_size   = var.disk_size
  accelerator = "kvm"

  headless         = var.headless
  http_directory   = "http"
  http_port_min    = 8100
  http_port_max    = 8150

  ssh_username     = "root"
  ssh_password     = "packer"
  ssh_timeout      = var.ssh_timeout
  shutdown_command = "true"

  boot_wait = "60s"
  boot_command = [
    "<enter><wait60>",
    "passwd<enter><wait>packer<enter><wait>packer<enter><wait>",
    "systemctl start sshd<enter><wait>",
    "curl -o /root/archinstall.json http://{{ .HTTPIP }}:{{ .HTTPPort }}/archinstall.json<enter><wait5>",
    "archinstall --config /root/archinstall.json --silent<enter>"
  ]

  qemuargs = [
    ["-cpu", "host"],
    ["-machine", "type=q35,accel=kvm"],
    ["-device", "virtio-gpu-pci"],
    ["-display", "gtk,gl=on"],
    ["-device", "virtio-net-pci,netdev=net0"],
    ["-netdev", "user,id=net0,hostfwd=tcp::{{ .SSHHostPort }}-:22"]
  ]
}

build {
  sources = ["source.qemu.arch-kde-plasma"]

  # Copy provisioning script
  provisioner "file" {
    source      = "scripts/arch-provision.sh"
    destination = "/tmp/provision.sh"
  }

  # Create user and run provisioning
  provisioner "shell" {
    inline = [
      "useradd -m -G wheel -s /bin/bash ${var.ssh_username}",
      "echo '${var.ssh_username}:${var.ssh_password}' | chpasswd",
      "echo '%wheel ALL=(ALL:ALL) NOPASSWD: ALL' >> /etc/sudoers",
      "chmod +x /tmp/provision.sh",
      "/tmp/provision.sh"
    ]
  }

  # Install KDE Plasma
  provisioner "shell" {
    inline = [
      "pacman -S --noconfirm plasma-meta kde-applications-meta sddm",
      "systemctl enable sddm",
      "systemctl set-default graphical.target"
    ]
  }

  # Clean up, strip build secrets, then power off
  provisioner "shell" {
    expect_disconnect = true
    inline = [
      "pacman -Scc --noconfirm",
      "rm -rf /var/cache/pacman/pkg/*",
      "passwd -l ${var.ssh_username}",
      "passwd -l root",
      "sed -i '/^%wheel ALL=(ALL:ALL) NOPASSWD: ALL$/d' /etc/sudoers",
      "rm -rf /tmp/*",
      "sync",
      "poweroff"
    ]
  }
}
