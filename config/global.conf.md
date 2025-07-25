# Global Configuration

This file contains system-wide default values used throughout the ZFS root installer.

## Configuration Categories

### ZFS Configuration
- **DEFAULT_POOL_NAME**: Default ZFS pool name (default: "zroot")
- **DEFAULT_MOUNT_BASE**: Base directory for mounting build datasets (default: "/var/tmp/zfs-builds")

### Distribution Configuration
- **DEFAULT_DISTRIBUTION**: Default Linux distribution (default: "ubuntu")
- **DEFAULT_ARCH**: Default target architecture (default: "amd64")

### Build Configuration
- **DEFAULT_VARIANT**: Default debootstrap variant (default: "apt")
- **DEFAULT_DOCKER_IMAGE**: Default Docker image for OS installation (default: "ubuntu:latest")

### Build Status and Logging
- **STATUS_DIR**: Directory for storing build status files (default: "/var/tmp/zfs-builds")
- **LOG_LEVEL**: Default logging level (default: "INFO")

### Container Configuration
- **CONTAINER_TIMEOUT**: Seconds to wait for container startup (default: 60)
- **CONTAINER_STOP_TIMEOUT**: Seconds to wait for graceful container stop (default: 10)
- **CONTAINER_CAPABILITIES**: systemd-nspawn capabilities (default: "all")
- **DEVICE_POLICY**: systemd-nspawn device policy (default: "auto")

### ZFS Dataset Configuration
- **DATASET_CANMOUNT**: Default canmount property for root datasets (default: "noauto")
- **DATASET_MOUNTPOINT**: Default mountpoint property for root datasets (default: "legacy")

### Snapshot Configuration
- **SNAPSHOT_RETAIN_COUNT**: Number of build snapshots to retain per stage (default: 10)
- **SNAPSHOT_PREFIX**: Prefix for build snapshots (default: "build")

### Network Configuration
- **RESOLV_CONF_MODE**: How to handle DNS in containers (default: "copy-host")
- **TIMEZONE_MODE**: Timezone configuration for containers (default: "auto")

## Usage

The configuration is automatically loaded by `lib/common.sh` and made available to all scripts as readonly variables. If the configuration file is missing, fallback defaults are used.

## Customization

To customize the installer for your environment:

1. Edit the values in `config/global.conf`
2. Restart any running builds to pick up the new configuration
3. Test with a new build to ensure the changes work as expected

## Examples

### Using a different ZFS pool:
```bash
DEFAULT_POOL_NAME="tank"
```

### Using a different mount base:
```bash
DEFAULT_MOUNT_BASE="/mnt/zfs-builds"
```

### Custom build directory structure:
```bash
STATUS_DIR="/opt/zfs-installer/status"
DEFAULT_MOUNT_BASE="/opt/zfs-installer/builds"
```
