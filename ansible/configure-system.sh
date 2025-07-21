#!/bin/bash

# Script to configure Ubuntu ZFS base image with Ansible
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

Configure Ubuntu ZFS base image using Ansible in chroot context.

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
    - Must be run from the ansible/ directory
    - Base image must be a valid Ubuntu filesystem
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

# Check if we're in the right directory
if [[ ! -f "$PLAYBOOK" ]]; then
    log "ERROR: Playbook '$PLAYBOOK' not found"
    log "Make sure you're running this from the ansible/ directory"
    exit 1
fi

if [[ ! -f "$INVENTORY" ]]; then
    log "ERROR: Inventory file '$INVENTORY' not found"
    exit 1
fi

# Load user configuration from config/user.env
USER_ENV="../config/user.env"
if [[ -f "$USER_ENV" ]]; then
    log "Loading user configuration from $USER_ENV"
    # Export variables from user.env so Ansible can access them
    set -a  # automatically export all variables
    source "$USER_ENV"
    set +a  # stop automatically exporting
    log "Loaded: USERNAME=$USERNAME, TIMEZONE=$TIMEZONE, LOCALE=$LOCALE"
else
    log "WARNING: $USER_ENV not found, using defaults"
fi

# Mount necessary filesystems for chroot
log "Preparing chroot environment..."
mount -o bind /proc "$BASE_IMAGE_PATH/proc" || true
mount -o bind /sys "$BASE_IMAGE_PATH/sys" || true  
mount -o bind /dev "$BASE_IMAGE_PATH/dev" || true
mount -o bind /dev/pts "$BASE_IMAGE_PATH/dev/pts" || true

# Function to cleanup on exit
cleanup() {
    log "Cleaning up chroot environment..."
    umount -l "$BASE_IMAGE_PATH/proc" 2>/dev/null || true
    umount -l "$BASE_IMAGE_PATH/sys" 2>/dev/null || true
    umount -l "$BASE_IMAGE_PATH/dev/pts" 2>/dev/null || true
    umount -l "$BASE_IMAGE_PATH/dev" 2>/dev/null || true
}
trap cleanup EXIT

# Copy user configuration to the base image
log "Copying configuration to base image..."
mkdir -p "$BASE_IMAGE_PATH/tmp/ansible-config"
cp -r . "$BASE_IMAGE_PATH/tmp/ansible-config/"
if [[ -f "$USER_ENV" ]]; then
    cp "$USER_ENV" "$BASE_IMAGE_PATH/tmp/ansible-config/"
fi

# Install Ansible in the base image if not present
log "Ensuring Ansible is available in base image..."
chroot "$BASE_IMAGE_PATH" /bin/bash -c "
    export DEBIAN_FRONTEND=noninteractive
    if ! command -v ansible-playbook >/dev/null 2>&1; then
        apt-get update
        apt-get install -y ansible
    fi
"

# Build ansible-playbook command for chroot execution
CHROOT_CMD="chroot $BASE_IMAGE_PATH /bin/bash -c \"
cd /tmp/ansible-config
"

# Load user.env in chroot if it exists
CHROOT_CMD+="if [[ -f user.env ]]; then
    set -a
    source user.env
    set +a
fi

"

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

CHROOT_CMD+="$ANSIBLE_CMD"
CHROOT_CMD+="\""

# Show what we're about to run
log "Running: $CHROOT_CMD"

# Execute the playbook in chroot
eval "$CHROOT_CMD"

log "Configuration completed successfully"
