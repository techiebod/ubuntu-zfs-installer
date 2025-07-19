#!/bin/bash
# Reapply Ansible config with decrypted secrets
set -euo pipefail

source ./config/user.env
export ANSIBLE_CONFIG=ansible/ansible.cfg

# decrypt secrets using sops (needs .agekey or GPG)
export ANSIBLE_VAULT_PASSWORD_FILE=~/.ansible-vault-pass  # optional if using ansible-vault

ansible-playbook ansible/playbook.yml
