# Ubuntu ZFS Installer

This repo provides a modular, version-controlled, and secure system to install and maintain an Ubuntu system on ZFS root, designed to work with ZFSBootMenu.

## 🧱 Project Structure

- `install.sh` — Bootstrap script for first-time ZFS + debootstrap install
- `realign.sh` — Manually reapply Ansible config to current system
- `config/` — Secrets and user/env configuration (secure via sops)
- `ansible/` — System configuration split into roles (base, docker, samba, etc.)
- `scripts/` — Utility scripts (e.g. dataset creation, sops setup)

## 🔒 Security

Secrets are stored in `config/secrets.sops.yaml` and encrypted using Mozilla [sops](https://github.com/mozilla/sops) and [age](https://github.com/FiloSottile/age).

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

