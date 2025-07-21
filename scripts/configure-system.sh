#!/bin/bash

# Script to configure Ubuntu ZFS base image with Ansible using systemd-nspawn
# Usage: ./configure-system.sh [OPTIONS] BASE_IMAGE_PATH

set -euo pipefail

# Default values
PLAYBOOK="site.yml"
INVENTORY="inventory"
TAGS=""
LIMIT=""
CHECK_MODE=false
VERBOSE=false
BASE_IMAGE_PATH=""

# Function to show usage
show_usage() {
    cat << EOF
Usage: $0 [OPTIONS] BASE_IMAGE_PATH

Configure Ubuntu ZFS base image using Ansible in systemd-nspawn container.

ARGUMENTS:
    BASE_IMAGE_PATH         Path to the base image directory (e.g., /mnt/ubuntu-base)

OPTIONS:
    -p, --playbook FILE     Ansible playbook to run (default: site.yml)
    -i, --inventory FILE    Inventory file (default: inventory)
    -t, --tags TAGS         Only run tasks with these tags (comma-separated)
    -l, --limit PATTERN     Limit to specific hosts
    -c, --check             Run in check mode (dry-run)
    -v, --verbose           Enable verbose output
    -h, --help              Show this help message

COMMON TAG EXAMPLES:
    -t base                 Only configure basic system (timezone, locale, hostname)
    -t timezone,locale      Only configure timezone and locale
    -t network              Only configure network settings
    -t docker               Only configure Docker
    -t etckeeper            Only configure etckeeper (Git for /etc)

EXAMPLES:
    # Configure everything in base image
    $0 /mnt/ubuntu-base

    # Only set timezone and locale
    $0 --tags timezone,locale /mnt/ubuntu-base

    # Dry-run to see what would change
    $0 --check /mnt/ubuntu-base

    # Verbose output for debugging
    $0 --verbose --tags base /mnt/ubuntu-base

REQUIREMENTS:
    - Must be run from the ansible/ directory or project root
    - Base image must be a valid Ubuntu filesystem
    - systemd-nspawn must be available on the host system
    - Will install Ansible inside the base image if needed
EOF
}

# Function to log messages
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" >&2
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -p|--playbook)
            PLAYBOOK="$2"
            shift 2
            ;;
        -i|--inventory)
            INVENTORY="$2"
            shift 2
            ;;
        -t|--tags)
            TAGS="$2"
            shift 2
            ;;
        -l|--limit)
            LIMIT="$2"
            shift 2
            ;;
        -c|--check)
            CHECK_MODE=true
            shift
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            show_usage
            exit 0
            ;;
        *)
            # Last argument should be the base image path
            if [[ -z "$BASE_IMAGE_PATH" ]]; then
                BASE_IMAGE_PATH="$1"
                shift
            else
                log "ERROR: Unknown option $1"
                echo "Use --help for usage information" >&2
                exit 1
            fi
            ;;
    esac
done

# Validate required argument
if [[ -z "$BASE_IMAGE_PATH" ]]; then
    log "ERROR: BASE_IMAGE_PATH is required"
    show_usage
    exit 1
fi

# Validate base image path
if [[ ! -d "$BASE_IMAGE_PATH" ]]; then
    log "ERROR: Base image path '$BASE_IMAGE_PATH' does not exist"
    exit 1
fi

if [[ ! -f "$BASE_IMAGE_PATH/etc/os-release" ]]; then
    log "ERROR: '$BASE_IMAGE_PATH' does not appear to be a valid Ubuntu filesystem"
    exit 1
fi

# Get script directory and ansible directory
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ansible_dir="$script_dir/../ansible"

# Check if we have the ansible directory and files
if [[ ! -f "$ansible_dir/$PLAYBOOK" ]]; then
    log "ERROR: Playbook '$PLAYBOOK' not found in $ansible_dir"
    exit 1
fi

if [[ ! -f "$ansible_dir/$INVENTORY" ]]; then
    log "ERROR: Inventory file '$INVENTORY' not found in $ansible_dir"
    exit 1
fi

# Load user configuration from config/user.env
USER_ENV="$script_dir/../config/user.env"
if [[ -f "$USER_ENV" ]]; then
    log "Loading user configuration from $USER_ENV"
    # Export variables from user.env so Ansible can access them
    set -a  # automatically export all variables
    source "$USER_ENV"
    set +a  # stop automatically exporting
    log "Loaded: USERNAME=$USERNAME, TIMEZONE=$TIMEZONE, LOCALE=$LOCALE, HOSTNAME=$HOSTNAME"
else
    log "WARNING: $USER_ENV not found, using defaults"
fi

# Prepare configuration for container
log "Preparing configuration for systemd-nspawn container..."
# Remove any existing configuration to ensure fresh copy
rm -rf "$BASE_IMAGE_PATH/opt/ansible-config"
mkdir -p "$BASE_IMAGE_PATH/opt/ansible-config"
cp -r "$ansible_dir"/* "$BASE_IMAGE_PATH/opt/ansible-config/"
cp -r "$script_dir/../config" "$BASE_IMAGE_PATH/opt/ansible-config/"

# Fix symlinks to point to correct relative paths in container
cd "$BASE_IMAGE_PATH/opt/ansible-config"
if [[ -L "host_vars" ]]; then
    rm host_vars
    ln -s ./config/host_vars host_vars
fi
if [[ -L "group_vars" ]]; then
    rm group_vars  
    ln -s ./config/group_vars group_vars
fi

if [[ -f "$USER_ENV" ]]; then
    cp "$USER_ENV" "$BASE_IMAGE_PATH/opt/ansible-config/"
fi

# Build the ansible-playbook command
ANSIBLE_CMD="ansible-playbook"
ANSIBLE_CMD+=" -i $INVENTORY"
ANSIBLE_CMD+=" $PLAYBOOK"

if [[ -n "$TAGS" ]]; then
    ANSIBLE_CMD+=" --tags $TAGS"
fi

if [[ -n "$LIMIT" ]]; then
    ANSIBLE_CMD+=" --limit $LIMIT"
fi

if [[ "$CHECK_MODE" == true ]]; then
    ANSIBLE_CMD+=" --check --diff"
    log "Running in CHECK MODE (dry-run)"
fi

if [[ "$VERBOSE" == true ]]; then
    ANSIBLE_CMD+=" -vv"
fi

log "Using systemd-nspawn container for Ansible execution"

# Build systemd-nspawn command with inline script execution
NSPAWN_CMD="systemd-nspawn"
NSPAWN_CMD+=" --directory=$BASE_IMAGE_PATH"
NSPAWN_CMD+=" --console=pipe"
NSPAWN_CMD+=" --machine=ubuntu-config-$$"
NSPAWN_CMD+=" --quiet"
NSPAWN_CMD+=" /bin/bash -c \""
NSPAWN_CMD+="set -euo pipefail && "
NSPAWN_CMD+="export DEBIAN_FRONTEND=noninteractive && "
NSPAWN_CMD+="export LC_ALL=C.UTF-8 && "
NSPAWN_CMD+="export LANG=C.UTF-8 && "
NSPAWN_CMD+="export LANGUAGE=C.UTF-8 && "
NSPAWN_CMD+="export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin && "
NSPAWN_CMD+="cd /opt/ansible-config && "
NSPAWN_CMD+="if [[ -f user.env ]]; then set -a; source user.env; set +a; fi && "
NSPAWN_CMD+="if ! command -v ansible-playbook >/dev/null 2>&1; then "
NSPAWN_CMD+="echo 'Installing Ansible...' && "
NSPAWN_CMD+="echo 'deb http://archive.ubuntu.com/ubuntu plucky main restricted universe multiverse' > /etc/apt/sources.list && "
NSPAWN_CMD+="echo 'deb http://archive.ubuntu.com/ubuntu plucky-updates main restricted universe multiverse' >> /etc/apt/sources.list && "
NSPAWN_CMD+="echo 'deb http://security.ubuntu.com/ubuntu plucky-security main restricted universe multiverse' >> /etc/apt/sources.list && "
NSPAWN_CMD+="apt-get update && apt-get install -y ansible python3-apt; "
NSPAWN_CMD+="fi && "
NSPAWN_CMD+="echo 'Installing Ansible role dependencies...' && "
NSPAWN_CMD+="ansible-galaxy install -r requirements.yml && "
NSPAWN_CMD+="$ANSIBLE_CMD"
NSPAWN_CMD+="\""

log "Running: $NSPAWN_CMD"
eval "$NSPAWN_CMD"

log "Configuration completed successfully"
