# Configuration Directory

This directory contains actual configuration files for your specific installation.

**Important:** This directory should NOT be committed to the public repository as it contains:
- Real hostnames and network configurations  
- References to encrypted secrets
- Environment-specific settings

## Setup

1. Copy example configurations from the `examples/` directory
2. Customize for your specific environment
3. Set up secrets encryption with SOPS
4. Keep this directory in your private repository or local only

## Files

- `host_vars/` - Host-specific configurations (one per server)
- `secrets.sops.yaml` - Encrypted secrets (passwords, API keys, etc.)
- `ansible/` - Ansible configuration files

## Security

- Never commit unencrypted secrets
- Use SOPS for all sensitive data
- Review configurations before applying to production
- Keep separate from public repository
