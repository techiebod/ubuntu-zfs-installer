# Ubuntu ZFS Installer

This repo provides a modular system to install and maintain an Ubuntu system on ZFS root, designed to work with ZFSBootMenu and use Ansible to maintain the OS and packages config.  The stages are:

- Create ZFS filesystems (/ and /var/log for the chosen OS)
- Unpack a base image and copy in key config items e.g. hostid
- Create a chroot/container to work with pre-first-boot
- Configure the base OS
- Install packages and configure them

Reboot into this at your lesuire and thanks to ZFSBootMenu make this a safe process!

Maintain the config through a realign script and then repeat as each OS is desired.

## 🧱 Project Structure

- `install.sh` — Bootstrap script for first-time ZFS + debootstrap install
- `realign.sh` — Manually reapply Ansible config to current system
- `config/` — Secrets and user/env configuration (secure via sops)
- `ansible/` — System configuration split into roles (base, docker, samba, etc.)
- `scripts/` — Utility scripts (e.g. dataset creation, sops setup)

## 🔒 Security

Secrets are stored in `config/secrets.sops.yaml` and encrypted using Mozilla [sops](https://github.com/mozilla/sops) and [age](https://github.com/FiloSottile/age).

## ⚙️ Configuration

### User Configuration

1. **Copy the example config**: `cp config/user.env.example config/user.env`
2. **Edit your settings**:

   ```bash
   USERNAME=yourusername
   TIMEZONE=Europe/London  # Find yours: timedatectl list-timezones
   LOCALE=en_GB.UTF-8      # Find yours: locale -a
   ```

### Secrets Configuration

1. **Install sops and age**: `apt install age sops`
2. **Generate age key**: `age-keygen -o ~/.config/sops/age/keys.txt`
3. **Setup sops config**: `./scripts/create-sops-config.sh`
4. **Edit secrets**: `sops config/secrets.sops.yaml`

The secrets file contains:

- User password hashes
- SSH authorized keys
- Any other sensitive configuration

### System Configuration

The system uses Ansible roles that are completely generic and reusable:

- **base**: Timezone, locale, hostname, essential packages
- **network**: Network configuration  
- **docker**: Docker installation and setup
- **samba**: File server setup
- **etckeeper**: Git-based /etc tracking

Configuration is loaded from:

1. `config/user.env` - Your personal settings
2. `config/secrets.sops.yaml` - Encrypted secrets
3. `ansible/group_vars/` - Role defaults and system-specific settings

### TODO

- [ ] Install `sops` and `age`
- [ ] Generate `~/.config/sops/age/keys.txt`
- [ ] Run `scripts/create-sops-config.sh` to generate `.sops.yaml`
- [ ] Encrypt `config/secrets.sops.yaml` with `sops -e -i config/secrets.sops.yaml`

## 🧪 Setup

1. Clone the repo
2. Run `install.sh` to bootstrap the base system into ZFS
3. Run `realign.sh` any time to reapply system config

## 📸 Version Control

- `/etc` is tracked using `etckeeper`
- Secrets are encrypted and stored safely in Git

---

Built for automation, reproducibility, and sanity. Designed for use with ZFSBootMenu and Ubuntu 24.04/25.04+.

