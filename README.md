# Ubuntu ZFS Installer

A comprehensive system for building and managing Ubuntu boot environments on ZFS. This toolkit provides automated creation of ZFS-optimized Ubuntu systems with proper boot environment management, using mmdebstrap for base system creation and Ansible for configuration.

## 📋 Prerequisites

This system assumes you have:

1. **ZFS Root Pool** - A working ZFS pool set up as your root filesystem (typically named `zroot`)
2. **ZFSBootMenu** - Installed and configured as your boot manager
3. **Basic ZFS Knowledge** - Familiarity with ZFS concepts like datasets, snapshots, and boot environments
4. **Existing ZFS System** - Currently running Ubuntu/Linux from a ZFS root dataset

### Distribution Support

While this toolkit has an **Ubuntu bias** (with smart version/codename mapping and online validation), it supports **any distribution compatible with mmdebstrap**, including:

- **Ubuntu** - Full featured support with online release validation
- **Debian** - Built-in version/codename mapping 
- **Devuan, Kali, Linux Mint** - Basic support (specify both version and codename)
- **Any mmdebstrap-compatible distribution** - Manual configuration required

Ubuntu-specific features (like `get-ubuntu-version.sh` and automatic codename derivation) gracefully degrade for other distributions while maintaining core functionality.

### ZFS Root Setup

If you don't have ZFS root already configured, you'll need to:

- Install ZFS and create a root pool (e.g., using [OpenZFS Root on Ubuntu](https://openzfs.github.io/openzfs-docs/Getting%20Started/Ubuntu/Ubuntu%2022.04%20Root%20on%20ZFS.html))
- Install [ZFSBootMenu](https://github.com/zbm-dev/zfsbootmenu) as your boot manager
- Configure your system to boot from ZFS datasets

This toolkit manages **additional boot environments** within your existing ZFS setup - it doesn't create the initial ZFS root infrastructure.

## 🏗️ Architecture Overview

This system creates **ZFS Boot Environments** - complete, independent Ubuntu installations that can be selected at boot time. Each boot environment is a separate ZFS dataset that can be updated, tested, and rolled back independently.

### Key Components

- **`build-new-root.sh`** — **Main orchestrator** that coordinates the complete build process
- **`create-zfs-datasets.sh`** — ZFS dataset and mount point management with conditional varlog mounting
- **`install-base-os.sh`** — Base OS creation using mmdebstrap (supports Ubuntu, Debian, and derivatives)
- **`configure-system.sh`** — System configuration using Ansible in systemd-nspawn containers
- **`get-ubuntu-version.sh`** — Ubuntu release validation and version/codename mapping utility
- **`lib/common.sh`** — Shared functionality and smart distribution validation

### ZFS Dataset Structure

```
{pool}/ROOT/{codename}         → Build environment root
{pool}/ROOT/{codename}/varlog  → Separate /var/log dataset for log management
```

Example for Ubuntu 25.04 "plucky":
```
zroot/ROOT/plucky        → /var/tmp/zfs-builds/plucky
zroot/ROOT/plucky/varlog → /var/tmp/zfs-builds/plucky/var/log
```

## 🚀 Quick Start

### 1. **One-Command Build** (Recommended)

Build a complete Ubuntu 25.04 system with hostname "myserver":

```bash
sudo ./scripts/build-new-root.sh --cleanup --verbose --codename plucky myserver myserver
```

This automatically:
- Creates ZFS datasets with conditional varlog mounting
- Builds Ubuntu 25.04 base system using mmdebstrap
- Applies Ansible configuration for "myserver"
- Handles all flag propagation and error checking

### 2. **Step-by-Step Build** (Advanced)

For more control, run each step manually:

```bash
# 1. Create ZFS datasets and mount points
sudo ./scripts/create-zfs-datasets.sh --cleanup --verbose plucky

# 2. Build base Ubuntu system (with conditional varlog mounting)
sudo ./scripts/install-base-os.sh --verbose --codename plucky /var/tmp/zfs-builds/plucky

# 3. Mount varlog after base system creation
sudo ./scripts/create-zfs-datasets.sh --mount-varlog plucky

# 4. Configure with Ansible
sudo ./scripts/configure-system.sh --verbose --limit myserver /var/tmp/zfs-builds/plucky
```

## ⚙️ Configuration

### Host Configuration

Each machine gets its own configuration file in `config/host_vars/machinename.yml`:

```yaml
---
# Basic system settings
base_hostname: myserver
base_timezone: "Europe/London"
base_locale: "en_GB.UTF-8"

# Network configuration (optional)
network_config:
  - name: eth0
    dhcp: true

# Package management
packages_to_install:
  - curl
  - htop
  - vim

packages_to_remove:
  - snapd
```

### User Configuration

Set your preferences in `config/user.env`:

```bash
# User account settings
USERNAME=henry
USER_FULL_NAME="Henry Smith"
USER_PASSWORD_HASH="$6$rounds=4096$..."

# Localization
TIMEZONE="Europe/London"
LOCALE="en_GB.UTF-8"
KEYMAP="uk"

# SSH Configuration
SSH_AUTHORIZED_KEYS="ssh-ed25519 AAAAC3..."
```

### Secrets Management

Encrypted secrets in `config/secrets.sops.yaml`:

```yaml
# Encrypted with SOPS
user_password_hash: ENC[AES256_GCM,data:...,tag:...]
ssh_keys:
    authorized: ENC[AES256_GCM,data:...,tag:...]
```

## 🛠️ Advanced Usage

### Distribution Support

The system supports multiple distributions with smart version/codename mapping:

```bash
# Ubuntu versions - specify either version OR codename
sudo ./scripts/build-new-root.sh --codename plucky    # Ubuntu 25.04
sudo ./scripts/build-new-root.sh --version 24.04      # Ubuntu 24.04 (noble)

# Debian versions
sudo ./scripts/build-new-root.sh --distribution debian --codename bookworm

# Other distributions (requires both version and codename)
sudo ./scripts/build-new-root.sh --distribution fedora --version 39 --codename rawhide
```

### ZFS Boot Environment Management

List existing boot environments:

```bash
sudo ./scripts/create-zfs-datasets.sh --list
```

Output example:
```
CODENAME     MOUNT POINT          USED     STATUS               VARLOG
--------     -----------          ----     ------               ------
noble        /                    2.1G     (current system)     156M
plucky       legacy               1.8G     (in-progress build)  89M
jammy        /                    1.9G     (boot option)        234M

zpool bootfs: zroot/ROOT/noble
Actually mounted as /: zroot/ROOT/noble
Pool available space: 45.2G
```

### Flag Standardization

All scripts support consistent flags:

```bash
--verbose      # Enable verbose output
--dry-run      # Show commands without executing
--debug        # Enable debug output
--help         # Show help message
```

Flags are automatically propagated from the orchestrator to all child scripts.

### Conditional Varlog Mounting

The system handles mmdebstrap's requirement for empty directories elegantly:

- During base OS creation: varlog is not mounted (satisfies mmdebstrap)
- After base OS creation: varlog is mounted with automatic log rotation
- Existing logs are preserved as `/var/log.old`

## 📋 Workflow Details

### Complete Build Process

1. **Dataset Creation** (`create-zfs-datasets.sh`)
   - Creates `{pool}/ROOT/{codename}` and `{pool}/ROOT/{codename}/varlog`
   - Sets `mountpoint=legacy` for build safety
   - Conditionally mounts varlog (skipped during mmdebstrap)

2. **Base OS Installation** (`install-base-os.sh`)
   - Uses mmdebstrap in Docker for clean, reproducible builds
   - Online Ubuntu release validation using `get-ubuntu-version.sh`
   - Creates minimal, ZFS-optimized base system

3. **Varlog Mounting** (`create-zfs-datasets.sh --mount-varlog`)
   - Mounts varlog dataset after base system creation
   - Preserves existing logs as `/var/log.old`

4. **System Configuration** (`configure-system.sh`)
   - Uses systemd-nspawn for isolated configuration
   - Applies Ansible roles and host-specific configuration
   - Handles user accounts, packages, services, etc.

### Boot Environment Deployment

When ready to use the new boot environment:

```bash
# Set as boot default
sudo zfs set mountpoint=/ zroot/ROOT/plucky
sudo zpool set bootfs=zroot/ROOT/plucky zroot

# Reboot and select from GRUB menu
sudo reboot
```

## 🔧 Development

### Project Structure

```
├── scripts/                    # Main executables
│   ├── build-new-root.sh      # Main orchestrator
│   ├── create-zfs-datasets.sh # ZFS management
│   ├── install-base-os.sh     # Base OS creation
│   ├── configure-system.sh    # Ansible configuration
│   └── get-ubuntu-version.sh  # Ubuntu release utility
├── lib/
│   └── common.sh              # Shared functionality
├── config/
│   ├── host_vars/             # Per-machine configuration
│   ├── user.env               # User preferences
│   └── secrets.sops.yaml      # Encrypted secrets
└── ansible/                   # Ansible roles and playbooks
    ├── playbook.yml
    └── roles/
        ├── base/              # Base system setup
        ├── docker/            # Docker installation
        ├── etckeeper/         # Configuration tracking
        ├── network/           # Network configuration
        └── samba/             # File sharing
```

### Common Library Features

- **Smart distribution validation** with online Ubuntu release checking
- **Consistent flag handling** across all scripts
- **Proper error handling** with detailed messages
- **Dry-run support** for safe testing
- **Centralized logging** with debug levels

### System Roles

The system uses a mix of custom and community-maintained Ansible roles:

- **base**: System basics (timezone, locale, hostname, packages, ZFS optimization)
- **etckeeper**: Git-based /etc tracking  
- **network**: Network configuration via netplan
- **docker**: Docker installation
- **samba**: File server setup

## 🔒 Security

Secrets are encrypted using Mozilla [sops](https://github.com/mozilla/sops):

1. **Install tools**: `apt install age sops`
2. **Generate key**: `age-keygen -o ~/.config/sops/age/keys.txt`
3. **Setup sops**: `./scripts/create-sops-config.sh`
4. **Edit secrets**: `sops config/secrets.sops.yaml`

## 🛡️ Safety Features

### ZFS Protection

- **Legacy mounting** prevents accidental auto-mounting
- **ZFS built-in safety** prevents destroying mounted datasets
- **Mount point validation** prevents conflicts
- **Boot environment isolation** ensures system stability

### Build Validation

- **Online release validation** using Ubuntu APIs
- **Distribution compatibility checking**
- **Mount point safety verification**
- **Proper cleanup on failure**

## 📚 Examples

### Build Multiple Environments

```bash
# Build LTS version
sudo ./scripts/build-new-root.sh --cleanup --codename noble server-lts server-lts

# Build latest version  
sudo ./scripts/build-new-root.sh --cleanup --codename plucky server-latest server-latest

# Build Debian alternative
sudo ./scripts/build-new-root.sh --cleanup --distribution debian --codename bookworm debian-server debian-server
```

### Configuration Tags

Run only specific configuration tasks:

```bash
# Only configure Docker
sudo ./scripts/configure-system.sh --tags docker myserver /var/tmp/zfs-builds/plucky

# Only configure base system (timezone, locale, hostname)  
sudo ./scripts/configure-system.sh --tags base myserver /var/tmp/zfs-builds/plucky

# Multiple tags
sudo ./scripts/configure-system.sh --tags base,network myserver /var/tmp/zfs-builds/plucky
```

### Configuration Updates

Apply Ansible changes to existing system:

```bash
# Update running system
sudo ./scripts/realign.sh

# Update specific boot environment
sudo ./scripts/configure-system.sh --limit server-name /var/tmp/zfs-builds/plucky
```

### Recovery and Rollback

```bash
# List boot environments
sudo ./scripts/create-zfs-datasets.sh --list

# Rollback to previous environment
sudo zfs set mountpoint=/ zroot/ROOT/noble
sudo zpool set bootfs=zroot/ROOT/noble zroot
sudo reboot
```

## 🏆 Why This Approach?

- **🔒 Safe Testing** - Test system changes in isolated boot environments
- **⚡ Fast Rollback** - Instant rollback to known-good configurations
- **🎯 Reproducible** - Consistent builds using declarative configuration
- **🧹 Clean Separation** - Separate concerns: ZFS, base OS, configuration
- **🔧 Maintainable** - Modular scripts with shared functionality
- **📈 Scalable** - Easy to manage multiple systems and configurations

This system provides enterprise-grade boot environment management with the simplicity of a single command.

---

Built for automation, reproducibility, and simplicity. Designed for ZFS-based Ubuntu systems with proper boot environment management.
