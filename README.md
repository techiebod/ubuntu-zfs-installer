# Ubuntu ZFS Installer

[![CI Status](https://github.com/techiebod/ubuntu-zfs-installer/workflows/Shell%20Script%20Quality%20Checks/badge.svg)](https://github.com/techiebod/ubuntu-zfs-installer/actions)
[![Tests](https://img.shields.io/badge/tests-227%20passing-brightgreen)](https://github.com/techiebod/ubuntu-zfs-installer/actions)
[![Coverage](https://img.shields.io/badge/coverage-100%25-brightgreen)](#-testing)

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
- **`manage-root-datasets.sh`** — ZFS dataset and mount point management with conditional varlog mounting
- **`install-root-os.sh`** — Base OS creation using mmdebstrap (supports Ubuntu, Debian, and derivatives)
- **`configure-root-os.sh`** — System configuration using Ansible in systemd-nspawn containers
- **`manage-root-containers.sh`** — Container lifecycle management for build and runtime environments
- **`manage-root-snapshots.sh`** — ZFS snapshot creation, listing, rollback, and cleanup
- **`manage-build-status.sh`** — Build status tracking and resumability management
- **`get-ubuntu-version.sh`** — Ubuntu release validation and version/codename mapping utility
- **`get-ubuntu-packages.sh`** — Ubuntu package list generation with blacklist filtering
- **`lib/core.sh`** — Core initialization and modular library loading

### ZFS Dataset Structure

```
```
{pool}/ROOT/{codename}         → Build environment root
{pool}/ROOT/{codename}/varlog  → Separate /var/log dataset for log management
```

Where `{pool}` defaults to `zroot` and `ROOT` is configurable via `DEFAULT_ROOT_DATASET` in `config/global.conf`.

Example mapping:
```
zroot/ROOT/plucky        → /var/tmp/zfs-builds/plucky
zroot/ROOT/plucky/varlog → /var/tmp/zfs-builds/plucky/var/log
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
sudo ./scripts/build-new-root.sh --verbose --codename plucky plucky-build myserver
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
sudo ./scripts/manage-root-datasets.sh --verbose create plucky-build

# 2. Build base Ubuntu system (with conditional varlog mounting)
sudo ./scripts/install-root-os.sh --verbose --codename plucky --pool zroot plucky-build

# 3. Mount varlog after base system creation
sudo ./scripts/manage-root-datasets.sh --verbose mount-varlog plucky-build

# 4. Configure with Ansible
sudo ./scripts/configure-root-os.sh --tags docker --pool zroot plucky-build myserver

sudo ./scripts/configure-root-os.sh --tags base --pool zroot plucky-build myserver

sudo ./scripts/configure-root-os.sh --tags base,network --pool zroot plucky-build myserver
```

## 📸 ZFS Snapshots & Change Tracking

### Automated Build Snapshots

The system creates ZFS snapshots at each major build stage by default for easy rollback:

```bash
# Build with automatic snapshots (enabled by default)
sudo ./scripts/build-new-root.sh --verbose --codename plucky plucky-build myserver

# Disable snapshots if not needed
sudo ./scripts/build-new-root.sh --no-snapshots --verbose --codename plucky plucky-build myserver
```

**Snapshot Stages Created:**
- `1-datasets-created` - After ZFS dataset creation
- `2-os-installed` - After mmdebstrap base OS installation  
- `3-varlog-mounted` - After varlog dataset mounting
- `4-container-created` - After container creation and preparation
- `5-ansible-configured` - After full Ansible configuration
- `6-completed` - After build completion and cleanup

### Snapshot Naming Convention

Snapshots follow the pattern: `build-stage-{stage}-{timestamp}`

Example: `zroot/{DEFAULT_ROOT_DATASET}/plucky@build-stage-2-os-installed-20250723-143022`

### Snapshot Management

```bash
# List all build snapshots
sudo ./scripts/manage-root-snapshots.sh list plucky-build

# Create manual snapshot
sudo ./scripts/manage-root-snapshots.sh create plucky-build custom-stage

# Rollback to specific stage
sudo ./scripts/manage-root-snapshots.sh rollback plucky-build build-stage-1-datasets-created-20250723-143022

# Clean up old snapshots (keeps latest 5)
sudo ./scripts/manage-root-snapshots.sh cleanup plucky-build datasets-created
```

### Offsite Replication, Bookmarks, and syncoid

For offsite or remote backup, this system supports common ZFS replication workflows using tools like [syncoid](https://github.com/jimsalterjrs/sanoid), [zrepl](https://zrepl.github.io/), or native `zfs send/receive` with bookmarks.

- **Local snapshot retention** is managed by sanoid or your chosen snapshot tool (e.g., keep 30 daily snapshots).
- **Bookmarks** are automatically left behind for each snapshot sent to a remote system. These bookmarks are lightweight pointers that remain even after the original snapshot is deleted locally.
- **Purpose of bookmarks:** Bookmarks allow replication tools to resume incremental replication from the last sent snapshot, even if the local snapshot has been pruned. They also serve as restore points for offsite recovery.
- **Automation:** You can automate replication using systemd timers, cron jobs, or other scheduling tools as appropriate for your environment.

**Best practice:**

> Local snapshots are pruned according to your retention policy, but bookmarks persist for all snapshots sent offsite. This enables efficient, reliable incremental replication and offsite restore, without cluttering your local system with old snapshots.

This is a recommended and widely used approach for ZFS backup and disaster recovery.

### Etckeeper Integration

All `/etc` changes are automatically tracked in git with meaningful commit messages:

- **Automatic tracking** of all package installations
- **Ansible integration** with context-aware commits
- **No backup files** - git provides complete change history
- **Role-specific commits** showing exactly what each Ansible role changed

```bash
# View configuration change history
sudo chroot /var/tmp/zfs-builds/plucky-build git -C /etc log --oneline

# See what files were changed in last commit
sudo chroot /var/tmp/zfs-builds/plucky-build git -C /etc show --name-only
```

**Example commit messages:**
```
Configure fstab for blackbox
Applied base role - system configuration updated
committing changes in /etc made by apt install docker-ce
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
sudo ./scripts/manage-root-datasets.sh list
```

Output example:
```
CODENAME     MOUNT POINT          USED     STATUS               VARLOG
--------     -----------          ----     ------               ------
noble        /                    2.1G     (current system)     156M
plucky       legacy               1.8G     (in-progress build)  89M
jammy        /                    1.9G     (boot option)        234M

```
zpool bootfs: zroot/{DEFAULT_ROOT_DATASET}/noble
Actually mounted as /: zroot/{DEFAULT_ROOT_DATASET}/noble
```
Pool available space: 45.2G
```

### Flag Standardization

All scripts support consistent flags:

```bash
--verbose      # Enable verbose output
--dry-run      # Show commands without executing
--debug        # Enable debug output
--snapshots    # Force enable ZFS snapshots (enabled by default)
--no-snapshots # Disable ZFS snapshots at build stages
--cleanup      # Remove existing build datasets before starting
--help         # Show help message
```

Flags are automatically propagated from the orchestrator to all child scripts.

### Container Management

The system provides dedicated container management for running Ansible and other tasks:

```bash
# Create container with Ansible pre-installed
sudo ./scripts/manage-root-containers.sh create --install-packages ansible,python3-apt ubuntu-noble

# Start container for interactive work
sudo ./scripts/manage-root-containers.sh start ubuntu-noble

# Get shell access to container
sudo ./scripts/manage-root-containers.sh shell ubuntu-noble

# Stop and destroy container when done
sudo ./scripts/manage-root-containers.sh destroy ubuntu-noble

# List all running containers
sudo ./scripts/manage-root-containers.sh list
```

This separation allows for:
- **Build-time configuration** - Automated during system creation
- **Live system management** - Run Ansible against booted systems
- **Interactive debugging** - Shell access to containers for troubleshooting

### Conditional Varlog Mounting

The system handles mmdebstrap's requirement for empty directories elegantly:

- During base OS creation: varlog is not mounted (satisfies mmdebstrap)
- After base OS creation: varlog is mounted with automatic log rotation
- Existing logs are preserved as `/var/log.old`

## 📋 Workflow Details

### Complete Build Process

The build process is now **resumable** with automatic status tracking:

1. **Dataset Creation** (`manage-root-datasets.sh`)
   - Creates `{pool}/{DEFAULT_ROOT_DATASET}/{codename}` and `{pool}/{DEFAULT_ROOT_DATASET}/{codename}/varlog`
   - Sets `mountpoint=legacy` for build safety
   - Status: `datasets-created`

2. **Base OS Installation** (`install-root-os.sh`)
   - Uses mmdebstrap in Docker for clean, reproducible builds
   - Online Ubuntu release validation using `get-ubuntu-version.sh`
   - Creates minimal, ZFS-optimized base system
   - Status: `os-installed`

3. **Varlog Mounting** (`manage-root-datasets.sh mount-varlog`)
   - Mounts varlog dataset after base system creation
   - Preserves existing logs as `/var/log.old`
   - Status: `varlog-mounted`

4. **Container Creation** (`manage-root-containers.sh`)
   - Creates systemd-nspawn container with Ansible pre-installed
   - Copies hostid for ZFS compatibility
   - Starts container with networking
   - Status: `container-created`

5. **System Configuration** (`configure-root-os.sh`)
   - Stages Ansible configuration into container
   - Executes Ansible playbooks against localhost
   - Handles user accounts, packages, services, etc.
   - Status: `ansible-configured`

6. **Cleanup and Completion**
   - Destroys temporary container
   - Marks build as complete
   - Status: `completed`

### Resumable Builds

If a build fails or is interrupted, simply re-run the same command:

```bash
# This will resume from where it left off
sudo ./scripts/build-new-root.sh --verbose plucky-build myserver

# Force restart from beginning
sudo ./scripts/build-new-root.sh --restart --verbose plucky-build myserver

# Check current build status
sudo ./scripts/manage-build-status.sh list
sudo ./scripts/manage-build-status.sh get plucky-build
```

**Build Status Tracking:**
- Status files stored in `/var/tmp/zfs-builds/BUILD_NAME.status`
- Each stage is only run if the previous stage completed successfully
- Failed builds can be resumed or restarted
- Supports multiple concurrent builds with different names

### Boot Environment Deployment

When ready to use the new boot environment:

```bash
# Set as boot default
```bash
sudo zfs set mountpoint=/ zroot/{DEFAULT_ROOT_DATASET}/plucky-build
sudo zpool set bootfs=zroot/{DEFAULT_ROOT_DATASET}/plucky-build zroot
```

# Reboot and select from GRUB menu
sudo reboot
```

## 🧪 Testing

The project maintains **100% test coverage** across all core functionality with comprehensive automated testing.

### Test Coverage

- **227 tests** across 11 test suites
- **100% pass rate** in continuous integration
- **Docker-based test environment** for consistency
- **Mock-based testing** for safe isolated execution

### Test Structure

```
test/
├── unit/                     # Comprehensive unit tests (227 tests)
│   ├── build-status.bats    # Build status management (40 tests)
│   ├── constants.bats       # System constants validation (6 tests)
│   ├── containers.bats      # Container lifecycle management (40 tests)
│   ├── core.bats            # Core library initialization (13 tests)
│   ├── execution.bats       # Command execution and dry-run (22 tests)
│   ├── logging.bats         # Logging system functionality (5 tests)
│   ├── recovery.bats        # Error handling and recovery (42 tests)
│   ├── ubuntu-api.bats      # Ubuntu API integration (12 tests)
│   ├── validation.bats      # Input validation and safety (6 tests)
│   └── zfs.bats             # ZFS dataset operations (38 tests)
├── integration/             # Integration tests (planned)
└── helpers/                 # Test utilities and mocks
    └── test_helper          # Common test setup and assertions
```

### Running Tests

Run all tests:
```bash
./tools/bats.sh test/unit/
```

Run specific test suites:
```bash
./tools/bats.sh test/unit/containers.bats    # Container operations
./tools/bats.sh test/unit/zfs.bats           # ZFS functionality  
./tools/bats.sh test/unit/core.bats          # Core system tests
```

### Test Features

- **🐳 Docker Integration** - Consistent test environment using bats-core
- **🎭 Comprehensive Mocking** - Safe testing without affecting real systems
- **🔄 CI/CD Integration** - Automated testing on every commit via GitHub Actions
- **📊 Quality Gates** - All tests must pass before merge
- **🛡️ Safety First** - Tests run in isolation without system modifications

### Continuous Integration

The project includes comprehensive CI/CD with:

- **ShellCheck Analysis** - Static analysis for shell script quality
- **Syntax Validation** - Bash syntax checking across all scripts
- **Permission Auditing** - Executable permission validation
- **YAML Validation** - Configuration file syntax checking
- **Documentation Checks** - Required documentation validation
- **Unit Test Execution** - Full test suite execution on every commit

## 🔧 Development

### Project Structure

```
├── scripts/                    # Main executables
│   ├── build-new-root.sh      # Main orchestrator with resumable builds
│   ├── manage-root-datasets.sh # ZFS dataset management
│   ├── install-root-os.sh     # Base OS creation
│   ├── configure-root-os.sh   # Ansible configuration
│   ├── manage-root-containers.sh # Container lifecycle management
│   ├── manage-root-snapshots.sh # ZFS snapshot management
│   ├── manage-build-status.sh # Build status and resumability
│   ├── get-ubuntu-version.sh  # Ubuntu release utility
│   └── get-ubuntu-packages.sh # Ubuntu package list generation
├── lib/
│   └── core.sh                # Core initialization and library loading
├── config/
│   ├── global.conf            # System-wide configuration
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
- **Consistent flag handling** across all scripts using [shflags](lib/vendor/SHFLAGS_STANDARDS.md)
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
3. **Setup sops**: Create `.sops.yaml` configuration file in project root
4. **Edit secrets**: `sops config/secrets.sops.yaml`

## 🛡️ Safety Features

### ZFS Protection

- **Legacy mounting** prevents accidental auto-mounting
- **ZFS built-in safety** prevents destroying mounted datasets
- **Mount point validation** prevents conflicts
- **Boot environment isolation** ensures system stability

### Multi-Layer Recovery

- **ZFS Snapshots** - Filesystem-level rollback to any build stage
- **Etckeeper Git History** - Configuration-level change tracking and rollback
- **Build Stage Isolation** - Each stage can be independently recovered
- **Automatic Cleanup** - Old snapshots automatically removed (keeps latest 5)

### Build Validation

- **Online release validation** using Ubuntu APIs
- **Distribution compatibility checking**
- **Mount point safety verification**
- **Proper cleanup on failure**
- **Dry-run support** for safe testing

## 📚 Examples

### Build Multiple Environments

```bash
# Build LTS version (snapshots enabled by default)
sudo ./scripts/build-new-root.sh --verbose --codename noble noble-server server-lts

# Build latest version with full debugging
sudo ./scripts/build-new-root.sh --verbose --debug --codename plucky plucky-server server-latest

# Build Debian alternative without snapshots
sudo ./scripts/build-new-root.sh --no-snapshots --verbose --distribution debian --codename bookworm debian-server debian-server
```

### Snapshot Workflow

```bash
# Build with snapshots enabled
sudo ./scripts/build-new-root.sh --snapshots --verbose --codename plucky test-build myserver

# Later: rollback to base OS if needed
sudo ./scripts/manage-root-snapshots.sh list test-build
sudo ./scripts/manage-root-snapshots.sh rollback test-build build-stage-2-os-installed-20250723-143022

# Continue from base OS state
sudo ./scripts/manage-root-datasets.sh mount-varlog test-build  
sudo ./scripts/configure-root-os.sh --limit myserver --pool zroot test-build myserver

# Create new snapshot after manual changes
sudo ./scripts/manage-root-snapshots.sh create test-build manual-changes
```

### Resumable Build Workflow

Manage long-running builds with automatic resumption:

```bash
# Start a build
sudo ./scripts/build-new-root.sh --snapshots --verbose ubuntu-test myserver

# If interrupted, check status
sudo ./scripts/manage-build-status.sh get ubuntu-test
# Output: os-installed

# Resume from where it left off
sudo ./scripts/build-new-root.sh --verbose ubuntu-test myserver
# Only runs remaining stages: varlog-mounted, container-created, ansible-configured, completed

# Monitor all builds
sudo ./scripts/manage-build-status.sh list
# Output:
# Build Status Summary:
# ====================
# ubuntu-test          ansible-configured   2025-07-25T08:42:15+00:00
# production           completed            2025-07-25T07:30:22+00:00

# Force complete restart if needed
sudo ./scripts/build-new-root.sh --restart --verbose ubuntu-test myserver
```

### Container-Based Management

Use containers for ongoing system management:

```bash
# Create management container for live system
sudo ./scripts/manage-root-containers.sh create --install-packages ansible,python3-apt production-system

# Start container
sudo ./scripts/manage-root-containers.sh start production-system

# Run specific Ansible tasks
sudo ./scripts/manage-root-containers.sh shell production-system
# Inside container:
cd /opt/ansible-config
ansible-playbook -i inventory site.yml --tags docker --limit production-host

# Clean up when done
sudo ./scripts/manage-root-containers.sh destroy production-system
```

### Configuration Tags

Run only specific configuration tasks:

```bash
# Only configure Docker
sudo ./scripts/configure-root-os.sh --tags docker --pool zroot plucky-build myserver

# Only configure base system (timezone, locale, hostname)  
sudo ./scripts/configure-root-os.sh --tags base --pool zroot plucky-build myserver

# Multiple tags
sudo ./scripts/configure-root-os.sh --tags base,network --pool zroot plucky-build myserver
```

### Configuration Updates

Apply Ansible changes to existing system:

```bash
# Update running system (requires creating container for live system)
sudo ./scripts/manage-root-containers.sh create --install-packages ansible,python3-apt current-system
sudo ./scripts/manage-root-containers.sh start current-system  
sudo ./scripts/configure-root-os.sh --limit server-name --pool zroot current-system server-name

# Update specific boot environment
sudo ./scripts/configure-root-os.sh --limit server-name --pool zroot plucky-build server-name
```

### Recovery and Rollback

```bash
# List boot environments
sudo ./scripts/manage-root-datasets.sh list

# List all snapshots for a build
sudo ./scripts/manage-root-snapshots.sh list plucky-build

# Rollback to previous environment
```bash
sudo zfs set mountpoint=/ zroot/{DEFAULT_ROOT_DATASET}/noble
sudo zpool set bootfs=zroot/{DEFAULT_ROOT_DATASET}/noble zroot
```
sudo reboot

# Rollback to specific build stage
sudo ./scripts/manage-root-snapshots.sh rollback plucky-build build-stage-2-os-installed-20250723-143022

# View configuration change history
sudo chroot /var/tmp/zfs-builds/plucky-build git -C /etc log --oneline

# Rollback specific file changes
sudo chroot /var/tmp/zfs-builds/plucky-build git -C /etc checkout HEAD~1 -- fstab
```

## 🏆 Why This Approach?

- **🔒 Safe Testing** - Test system changes in isolated boot environments with automatic snapshots
- **⚡ Multi-Level Rollback** - Filesystem snapshots + git history provide granular recovery options
- **🎯 Reproducible** - Consistent builds using declarative configuration with full audit trails
- **🧹 Clean Separation** - Separate concerns: ZFS, base OS, configuration tracking
- **🔧 Maintainable** - Modular scripts with shared functionality and comprehensive change tracking  
- **📈 Scalable** - Easy to manage multiple systems and configurations with automated cleanup
- **🔍 Auditable** - Complete change history through etckeeper + ZFS snapshots

This system provides enterprise-grade boot environment management with professional change tracking and the simplicity of a single command.

---

Built for automation, reproducibility, and simplicity. Designed for ZFS-based Ubuntu systems with proper boot environment management.

## 📄 License

This project is licensed under the Apache License 2.0 - see the [LICENSE](LICENSE) file for details.

This project includes third-party software:
- **shflags** by Kate Ward - Apache License 2.0
- See [NOTICE](NOTICE) file for full attribution
