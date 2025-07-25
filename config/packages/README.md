# Package Configuration

This directory contains package configuration files for different Linux distributions used by the ZFS root installer.

## Configuration Files

- `ubuntu.conf` - Package configuration for Ubuntu distributions
- `debian.conf` - Package configuration for Debian distributions

## Configuration Format

Each configuration file defines the following variables:

### Package Categories

- **CORE_PACKAGES**: Essential system packages required for basic functionality
- **NETWORK_PACKAGES**: Networking tools and utilities (ip, ping, curl, etc.)
- **ZFS_PACKAGES**: ZFS-related packages required for ZFS root functionality
- **SYSTEM_PACKAGES**: System management utilities and kernel packages
- **DEVELOPMENT_PACKAGES**: Development tools and automation packages (optional)
- **KEYRING_PACKAGES**: Distribution-specific keyring packages

### APT Configuration

- **APT_COMPONENTS**: Components to include in APT sources (e.g., "main,universe" for Ubuntu)

## Adding New Distributions

To add support for a new distribution:

1. Create a new configuration file named `{distribution}.conf`
2. Define all required package categories
3. Set appropriate APT components for the distribution
4. Test the configuration with a build

## Example Configuration

```bash
# Core system packages
CORE_PACKAGES="ca-certificates,systemd,init,apt"

# Networking packages
NETWORK_PACKAGES="iproute2,net-tools,iputils-ping,curl"

# ZFS packages
ZFS_PACKAGES="zfsutils-linux,zfs-initramfs"

# System packages
SYSTEM_PACKAGES="linux-image-generic,dbus"

# Optional packages
DEVELOPMENT_PACKAGES="ansible,python3-apt"
KEYRING_PACKAGES="ubuntu-keyring"

# APT configuration
APT_COMPONENTS="main,universe"
```

## Package Differences Between Distributions

Common differences between distributions:

- **Kernel packages**: Ubuntu uses `linux-image-generic`, Debian uses `linux-image-amd64`
- **APT components**: Ubuntu includes "universe", Debian includes "contrib,non-free"
- **Keyring packages**: Ubuntu uses `ubuntu-keyring`, Debian uses `debian-archive-keyring`
- **Package availability**: Some packages may have different names or not be available
