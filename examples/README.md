# Ubuntu ZFS Installer - Example Configurations

This directory contains example configurations to help you set up your own Ubuntu ZFS server installations.

## Structure

```
examples/
├── host_vars/              # Example host-specific configurations
│   ├── ubuntu-minimal.yml          # Minimal Ubuntu server
│   ├── ubuntu-docker-samba.yml     # Ubuntu with Docker and Samba
│   └── example-debian.yml          # Debian-based configuration
├── config/
│   └── distributions.conf          # Distribution-specific settings
├── inventory.example               # Example Ansible inventory
└── secrets.sops.yaml.example      # Example secrets file structure
```

## Usage

1. **Copy the example inventory:**
   ```bash
   cp examples/inventory.example config/ansible/inventory
   ```

2. **Create your host configuration:**
   ```bash
   cp examples/host_vars/ubuntu-minimal.yml config/host_vars/your-hostname.yml
   ```

3. **Set up secrets:**
   ```bash
   cp examples/secrets.sops.yaml.example config/secrets.sops.yaml
   # Edit and encrypt with SOPS
   sops config/secrets.sops.yaml
   ```

4. **Customize for your environment:**
   - Edit the hostname in your host_vars file
   - Configure network settings for your hardware
   - Add or remove services as needed
   - Update user accounts and passwords

## Example Configurations

### Minimal Ubuntu Server
- Basic system configuration
- Single user account
- Essential packages only

### Docker + Samba Server  
- Docker with Docker Compose
- Samba file sharing
- User configured for both services

### Debian Alternative
- Shows how to use Debian instead of Ubuntu
- Distribution-specific package names
- Custom mirror configuration

## Security Notes

- Always encrypt your secrets file with SOPS
- Never commit real passwords or sensitive data
- Keep your actual config/ directory separate from this public repo
- Review all configurations before applying to production systems
