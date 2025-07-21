# Ubuntu ZFS Installer

This repo provides a simplified system to configure Ubuntu systems on ZFS using Ansible built initially in systemd-nspawn containers. The system creates a ZFS-optimized Ubuntu base image and configures it with a clean, maintainable Ansible setup.

## 🧱 Project Structure

- `scripts/create-ubuntu-base.sh` — Create ZFS-optimized Ubuntu base images
- `scripts/configure-system.sh` — Main script to configure systems using systemd-nspawn + Ansible
- `config/host_vars/` — Per-machine configuration (hostname, network, packages, etc.)
- `config/user.env` — User settings (username, timezone, locale)
- `config/secrets.sops.yaml` — Encrypted secrets (passwords, SSH keys)
- `ansible/` — System configuration using roles and maintained community roles
- `scripts/realign.sh` — Apply Ansible config to running system

## � Quick Start

1. **Configure your machine**: Copy and edit a host configuration

   ```bash
   cp config/host_vars/blackbox.yml config/host_vars/yourmachine.yml
   # Edit the file with your settings
   ```

2. **Set user preferences**:

   ```bash
   cp config/user.env.example config/user.env
   # Edit with your username, timezone, locale
   ```

3. **Configure a base image**:

   ```bash
   sudo ./scripts/configure-system.sh yourmachine /path/to/base/image
   ```

## ⚙️ Configuration

### Host Configuration

Each machine gets its own configuration file in `config/host_vars/machinename.yml`:

```yaml
---
# Basic system settings
base_hostname: yourmachine
base_timezone: "Europe/London"
base_locale: "en_GB.UTF-8"

# Network configuration (optional)
network_config:
  version: 2
  renderer: networkd
  ethernets:
    eth0:
      dhcp4: true

# Docker configuration (optional)
docker_install_compose: true
docker_users:
  - yourusername
docker_daemon_options:
  log-driver: "journald"
  data-root: "/var/lib/docker"

# Additional packages
extra_packages:
  - htop
  - vim
```

### System Roles

The system uses a mix of custom and community-maintained Ansible roles:

- **base**: System basics (timezone, locale, hostname, packages, ZFS optimization)
- **etckeeper**: Git-based /etc tracking  
- **network**: Network configuration via netplan
- **geerlingguy.docker**: Docker installation (community-maintained)
- **samba**: File server setup

## 🔒 Security

Secrets are encrypted using Mozilla [sops](https://github.com/mozilla/sops):

1. **Install tools**: `apt install age sops`
2. **Generate key**: `age-keygen -o ~/.config/sops/age/keys.txt`
3. **Setup sops**: `./scripts/create-sops-config.sh`
4. **Edit secrets**: `sops config/secrets.sops.yaml`

## � Advanced Usage

### Configuration Tags

Run only specific configuration tasks:

```bash
# Only configure Docker
sudo ./scripts/configure-system.sh --tags docker yourmachine /path/to/base/image

# Only configure base system (timezone, locale, hostname)  
sudo ./scripts/configure-system.sh --tags base yourmachine /path/to/base/image

# Multiple tags
sudo ./scripts/configure-system.sh --tags base,network yourmachine /path/to/base/image
```

### Applying to Running Systems

Use `realign.sh` to apply configuration to an already running system:

```bash
sudo ./scripts/realign.sh
```

## 📁 Directory Structure

```text
ubuntu-zfs-installer/
├── ansible/
│   ├── roles/
│   │   ├── base/           # System basics + ZFS optimization
│   │   ├── etckeeper/      # Git tracking for /etc
│   │   ├── network/        # Network configuration  
│   │   └── samba/          # File server setup
│   ├── requirements.yml    # External role dependencies
│   ├── site.yml           # Main playbook
│   └── inventory          # Inventory mapping
├── config/
│   ├── host_vars/         # Per-machine configuration
│   ├── user.env          # User preferences  
│   └── secrets.sops.yaml # Encrypted secrets
└── scripts/
    ├── create-ubuntu-base.sh  # Create ZFS-optimized base images
    ├── configure-system.sh    # Main configuration script
    ├── realign.sh            # Apply config to running system
    └── create-sops-config.sh # Setup encryption
```

## 🎯 Design Principles

- **Simple**: systemd-nspawn containers instead of complex chroot setups
- **Maintainable**: Use community roles where possible (e.g., geerlingguy.docker)
- **Clean separation**: Host-specific config separate from role defaults
- **ZFS optimized**: Proper sysctl settings for ZFS workloads
- **Secure**: Encrypted secrets, Git tracking of /etc changes

---

Built for automation, reproducibility, and simplicity. Designed for ZFS-based Ubuntu systems.

## 📋 Example Workflow

1. **Create base image** with `scripts/create-ubuntu-base.sh` (Ubuntu 25.04 with ZFS support)
2. **Copy and customize** a host configuration file
3. **Run configure-system.sh** to apply all configuration
4. **Use realign.sh** for ongoing maintenance
5. **Track changes** automatically via etckeeper
