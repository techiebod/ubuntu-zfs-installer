#!/bin/bash

# Script to create Ubuntu base image using mmdebstrap via Docker
# Usage: ./create_ubuntu_base.sh [OPTIONS] TARGET_DIR
# 
# This script uses the get-ubuntu-version.sh script to get Ubuntu version information
# and creates a minimal ZFS-ready base image using mmdebstrap running in a Docker container.
# The base image is designed to be configured with Ansible for machine-specific settings.

set -euo pipefail

# Default values
UBUNTU_VERSION=""
UBUNTU_CODENAME=""
TARGET_DIR=""
ARCH="amd64"
VARIANT="minbase"
MIRROR="http://archive.ubuntu.com/ubuntu"
DOCKER_IMAGE="ubuntu:latest"  # Latest LTS - can also use ubuntu:rolling for newest release or ubuntu:24.04 for specific LTS
PRESERVE_HOSTID=false
VERBOSE=false
DRY_RUN=false

# Function to show usage
show_usage() {
    cat << EOF
Usage: $0 [OPTIONS] TARGET_DIR

Create a minimal ZFS-ready Ubuntu base image using mmdebstrap via Docker.
Designed for use with ZFSBootMenu (GRUB is excluded and held to prevent installation).

OPTIONS:
    -v, --version VERSION    Ubuntu version (e.g., 25.04, 24.04)
                           If not specified, uses latest from get-ubuntu-version.sh
    -a, --arch ARCH         Target architecture (default: amd64)
    -m, --mirror URL        Ubuntu mirror URL (default: archive.ubuntu.com)
    --variant VARIANT       Debootstrap variant (default: minbase)
                           Options: essential, apt, required, minbase, buildd
    --docker-image IMAGE    Docker base image (default: ubuntu:latest)
    --preserve-hostid       Copy existing /etc/hostid from current system
                           Use this when updating an existing ZFS system
    --verbose               Enable verbose output
    --dry-run               Show commands without executing
    -h, --help              Show this help message

TARGET_DIR:
    Directory where the Ubuntu base image will be created.
    Will be created if it doesn't exist.

EXAMPLES:
    # Create latest Ubuntu base image in /mnt (recommended)
    $0 /mnt/ubuntu-base

    # Update existing ZFS system - preserve current hostid
    $0 --preserve-hostid /mnt/ubuntu-base

    # Create specific version with custom architecture
    $0 --version 24.04 --arch arm64 /mnt/ubuntu-arm64-base

    # Use custom mirror and rolling Docker image
    $0 --mirror http://us.archive.ubuntu.com/ubuntu --docker-image ubuntu:rolling /mnt/ubuntu-base

ZFS FEATURES:
    - Includes zfsutils-linux and zfs-initramfs
    - GRUB packages are excluded and held to prevent installation
    - Compatible with ZFSBootMenu for bootloader management
    - Generates /etc/hostid for consistent ZFS pool imports
    - Option to preserve existing hostid when updating systems

POST-INSTALL CONFIGURATION:
    This script creates a minimal base image. Machine-specific configuration
    should be done via Ansible playbooks, including:
    - /etc/fstab configuration
    - Network settings
    - User accounts
    - Timezone and locale
    - ZFS pool and dataset configuration

REQUIREMENTS:
    - Docker must be installed and running
    - get-ubuntu-version.sh script must be in the same directory or in PATH
    - jq (for Ubuntu version/codename lookup) - install with: apt install jq
EOF
}

# Function to log messages
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" >&2
}

# Function to run commands with optional dry-run
run_cmd() {
    if [[ "$VERBOSE" == true ]]; then
        log "Running: $*"
    fi
    
    if [[ "$DRY_RUN" == true ]]; then
        echo "DRY-RUN: $*"
        return 0
    fi
    
    "$@"
}

# Function to check if Docker is available
check_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        log "ERROR: Docker is not installed or not in PATH"
        exit 1
    fi
    
    if ! docker info >/dev/null 2>&1; then
        log "ERROR: Docker is not running or not accessible"
        log "Make sure Docker is running and you have permission to use it"
        exit 1
    fi
}

# Function to get Ubuntu version and codename
get_ubuntu_info() {
    local ubuntu_script=""
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    
    # Look for get-ubuntu-version.sh script
    if [[ -f "$script_dir/get-ubuntu-version.sh" ]]; then
        ubuntu_script="$script_dir/get-ubuntu-version.sh"
    elif [[ -f "./get-ubuntu-version.sh" ]]; then
        ubuntu_script="./get-ubuntu-version.sh"
    elif command -v get-ubuntu-version.sh >/dev/null 2>&1; then
        ubuntu_script="get-ubuntu-version.sh"
    else
        log "ERROR: get-ubuntu-version.sh script not found"
        log "Please ensure get-ubuntu-version.sh is in the same directory as this script or in PATH"
        exit 1
    fi
    
    # Get version and codename
    if [[ -z "$UBUNTU_VERSION" ]]; then
        # Get latest version
        UBUNTU_VERSION=$($ubuntu_script)
        if [[ $? -ne 0 ]] || [[ -z "$UBUNTU_VERSION" ]]; then
            log "ERROR: Failed to get Ubuntu version from $ubuntu_script"
            exit 1
        fi
        # Get codename for the latest version
        UBUNTU_CODENAME=$($ubuntu_script --codename)
    else
        # Version was specified, get the codename for this specific version
        UBUNTU_CODENAME=$($ubuntu_script --codename "$UBUNTU_VERSION")
        if [[ $? -ne 0 ]] || [[ -z "$UBUNTU_CODENAME" ]]; then
            log "ERROR: Could not get codename for Ubuntu $UBUNTU_VERSION"
            log "Please verify this is a valid Ubuntu version"
            exit 1
        fi
    fi
    
    # Warn if using a very new release that might not have stable keys
    if [[ "$UBUNTU_VERSION" > "24.10" ]]; then
        log "WARNING: Using very new Ubuntu release $UBUNTU_VERSION"
        log "If you encounter GPG key issues, try using --version 24.04 for the latest LTS"
    fi
    
    log "Using Ubuntu $UBUNTU_VERSION ($UBUNTU_CODENAME)"
}

# Function to create mmdebstrap command
create_mmdebstrap_cmd() {
    local target_path="/output"
    
    cat << EOF
mmdebstrap \\
    --verbose \\
    --arch=$ARCH \\
    --variant=$VARIANT \\
    --include=ca-certificates,ubuntu-keyring,systemd,init,linux-image-generic,zfsutils-linux,zfs-initramfs \\
    --keyring=/usr/share/keyrings/ubuntu-archive-keyring.gpg \\
    --customize-hook='if [ -x "\$1/usr/bin/apt-get" ]; then chroot "\$1" apt-get clean; fi' \\
    --customize-hook='rm -rf "\$1/var/lib/apt/lists/*"' \\
    --customize-hook='rm -rf "\$1/tmp/*"' \\
    --customize-hook='rm -rf "\$1/var/tmp/*"' \\
    --customize-hook='rm -rf "\$1/var/cache/apt/archives/*.deb"' \\
    --customize-hook='echo "grub-pc hold" | chroot "\$1" dpkg --set-selections' \\
    --customize-hook='echo "grub-pc-bin hold" | chroot "\$1" dpkg --set-selections' \\
    --customize-hook='echo "grub2-common hold" | chroot "\$1" dpkg --set-selections' \\
    --customize-hook='echo "grub-common hold" | chroot "\$1" dpkg --set-selections' \\
    --customize-hook='chroot "\$1" apt-mark hold grub-pc grub-pc-bin grub2-common grub-common 2>/dev/null || true' \\
    $UBUNTU_CODENAME \\
    $target_path \\
    $MIRROR
EOF
}

# Function to create the base image
create_base_image() {
    local abs_target_dir
    abs_target_dir=$(realpath "$TARGET_DIR")
    
    # Create target directory if it doesn't exist
    run_cmd mkdir -p "$abs_target_dir"
    
    # Generate mmdebstrap command
    local mmdebstrap_cmd
    mmdebstrap_cmd=$(create_mmdebstrap_cmd)
    
    log "Creating Ubuntu $UBUNTU_VERSION base image in $abs_target_dir"
    
    if [[ "$VERBOSE" == true ]]; then
        log "mmdebstrap command:"
        echo "$mmdebstrap_cmd" | sed 's/^/  /'
    fi
    
    # Run mmdebstrap in Docker container
    run_cmd docker run --rm \
        --privileged \
        -v "$abs_target_dir:/output" \
        $(if [[ "$PRESERVE_HOSTID" == true ]] && [[ -f "/etc/hostid" ]]; then echo "-v /etc/hostid:/host-hostid:ro"; fi) \
        "$DOCKER_IMAGE" \
        bash -c "
            set -euo pipefail
            echo 'Updating package lists...'
            apt-get update
            
            echo 'Installing mmdebstrap and dependencies...'
            apt-get install -y mmdebstrap ubuntu-keyring wget gnupg
            
            echo 'Updating Ubuntu keyring for latest releases...'
            # Refresh the Ubuntu keyring to ensure we have keys for newer releases
            wget -q -O /tmp/ubuntu-keyring.gpg https://archive.ubuntu.com/ubuntu/project/ubuntu-archive-keyring.gpg || true
            if [[ -s /tmp/ubuntu-keyring.gpg ]]; then
                cp /tmp/ubuntu-keyring.gpg /usr/share/keyrings/ubuntu-archive-keyring.gpg
                echo 'Updated Ubuntu keyring'
            fi
            
            echo 'Creating Ubuntu $UBUNTU_VERSION ($UBUNTU_CODENAME) base image...'
            $mmdebstrap_cmd
            
            # Handle hostid preservation
            if [[ -f /host-hostid ]]; then
                echo 'Preserving existing hostid from current system...'
                cp /host-hostid /output/etc/hostid
                echo \"Copied hostid: \$(cat /host-hostid | hexdump -C)\"
            fi
        "
    
    if [[ "$DRY_RUN" == false ]]; then
        # Check if basic filesystem structure was created
        if [[ -d "$abs_target_dir/bin" ]] && [[ -d "$abs_target_dir/etc" ]] && [[ -d "$abs_target_dir/usr" ]]; then
            local size
            size=$(du -sh "$abs_target_dir" 2>/dev/null | cut -f1 || echo "unknown")
            log "Successfully created ZFS-ready Ubuntu base image:"
            log "  Directory: $abs_target_dir"
            log "  Size: $size"
            log "  Version: Ubuntu $UBUNTU_VERSION ($UBUNTU_CODENAME)"
            log "  Architecture: $ARCH"
            log "  ZFS Support: Included (zfsutils-linux, zfs-initramfs)"
            if [[ "$PRESERVE_HOSTID" == true ]] && [[ -f "/etc/hostid" ]]; then
                local current_hostid
                current_hostid=$(hostid 2>/dev/null || echo "unknown")
                log "  Host ID: Preserved from current system ($current_hostid)"
            else
                log "  Host ID: Generated (/etc/hostid for consistent pool imports)"
            fi
            log "  Bootloader: GRUB excluded (use ZFSBootMenu)"
            log "  Next Steps: Configure with Ansible for machine-specific settings"
        else
            log "ERROR: Base image creation failed - filesystem structure not found"
            log "Expected directories like bin/, etc/, usr/ in: $abs_target_dir"
            exit 1
        fi
    fi
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -v|--version)
            UBUNTU_VERSION="$2"
            shift 2
            ;;
        -a|--arch)
            ARCH="$2"
            shift 2
            ;;
        -m|--mirror)
            MIRROR="$2"
            shift 2
            ;;
        --variant)
            VARIANT="$2"
            shift 2
            ;;
        --docker-image)
            DOCKER_IMAGE="$2"
            shift 2
            ;;
        --preserve-hostid)
            PRESERVE_HOSTID=true
            shift
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            show_usage
            exit 0
            ;;
        -*)
            log "ERROR: Unknown option $1"
            echo "Use --help for usage information" >&2
            exit 1
            ;;
        *)
            if [[ -z "$TARGET_DIR" ]]; then
                TARGET_DIR="$1"
            else
                log "ERROR: Multiple target directories specified"
                exit 1
            fi
            shift
            ;;
    esac
done

# Validate arguments
if [[ -z "$TARGET_DIR" ]]; then
    log "ERROR: TARGET_DIR is required"
    show_usage
    exit 1
fi

# Main execution
main() {
    log "Starting Ubuntu base image creation"
    
    check_docker
    get_ubuntu_info
    create_base_image
    
    log "Ubuntu base image creation completed"
}

# Run main function
main
