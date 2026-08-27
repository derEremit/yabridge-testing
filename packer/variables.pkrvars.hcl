# Common variables for Packer builds

# VM Configuration
vm_name           = "yabridge-test"
cpus              = 4
memory            = 8192
disk_size         = "50G"

# SSH Configuration
ssh_username      = "yabridge"
ssh_password      = "yabridge"
ssh_timeout       = "30m"

# Build Configuration
headless          = false
boot_wait         = "5s"

# Output
output_directory  = "output"
