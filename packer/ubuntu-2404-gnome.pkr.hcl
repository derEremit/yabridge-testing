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
  default = "ubuntu-2404-gnome"
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
  default = "30m"
}

variable "headless" {
  type    = bool
  default = false
}

variable "iso_url" {
  type    = string
  default = "https://releases.ubuntu.com/24.04/ubuntu-24.04.1-live-server-amd64.iso"
}

variable "iso_checksum" {
  type    = string
  default = "sha256:e240e4b801f7bb68c20d1356b60968ad0c33a41d00d828e74ceb3f66a3b7b8a8"
}

source "qemu" "ubuntu-2404-gnome" {
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

  ssh_username     = var.ssh_username
  ssh_password     = var.ssh_password
  ssh_timeout      = var.ssh_timeout
  shutdown_command = "true"

  boot_wait = "5s"
  boot_command = [
    "c<wait>",
    "linux /casper/vmlinuz --- autoinstall ds='nocloud-net;s=http://{{ .HTTPIP }}:{{ .HTTPPort }}/'<enter><wait>",
    "initrd /casper/initrd<enter><wait>",
    "boot<enter>"
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
  sources = ["source.qemu.ubuntu-2404-gnome"]

  # Wait for cloud-init to finish
  provisioner "shell" {
    inline = [
      "while [ ! -f /var/lib/cloud/instance/boot-finished ]; do echo 'Waiting for cloud-init...'; sleep 5; done"
    ]
  }

  # Copy provisioning script
  provisioner "file" {
    source      = "scripts/ubuntu-provision.sh"
    destination = "/tmp/provision.sh"
  }

  # Run provisioning
  provisioner "shell" {
    inline = [
      "chmod +x /tmp/provision.sh",
      "sudo /tmp/provision.sh"
    ]
  }

  # Install GNOME desktop
  provisioner "shell" {
    inline = [
      "sudo apt-get update",
      "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y ubuntu-desktop-minimal gnome-session",
      "sudo systemctl set-default graphical.target",
      "sudo systemctl enable gdm"
    ]
  }

  # Clean up, strip build secrets, then power off
  provisioner "shell" {
    expect_disconnect = true
    inline = [
      "sudo apt-get clean",
      "sudo rm -rf /var/lib/apt/lists/*",
      "sudo bash -c 'rm -f /etc/sudoers.d/yabridge; passwd -l yabridge; rm -rf /tmp/*; sync; shutdown -P now'"
    ]
  }
}
