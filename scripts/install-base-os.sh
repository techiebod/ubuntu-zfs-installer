#!/bin/bash

# Script to create base system image using mmdebstrap via Docker
# Usage: ./install-base-os.sh [OPTIONS] TARGET_DIR
# 
# This script creates a minimal ZFS-ready base image using mmdebstrap running in a Docker container.
# Supports Ubuntu, Debian, and other mmdebstrap-compatible distributions.
# The base image is designed to be configured with Ansible for machine-specific settings.

set -euo pipefail

# Source common library
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/../lib/common.sh"

# Default values
DISTRIBUTION="$DEFAULT_DISTRIBUTION"
VERSION=""
CODENAME=""
TARGET_DIR=""
ARCH="$DEFAULT_ARCH"
VARIANT="$DEFAULT_VARIANT"
MIRROR=""
DOCKER_IMAGE="$DEFAULT_DOCKER_IMAGE"
PRESERVE_HOSTID=false
CONFIGURE=false
ANSIBLE_TAGS=""

# Function to show usage
show_help() {
    cat << EOF
Usage: $0 [OPTIONS] TARGET_DIR

Create a minimal ZFS-ready base system image using mmdebstrap via Docker.
Supports Ubuntu, Debian, and other mmdebstrap-compatible distributions.
Designed for use with ZFSBootMenu (GRUB is excluded and held to prevent installation).

OPTIONS:
    -d, --distribution DIST  Distribution (ubuntu, debian, or any mmdebstrap-compatible) (default: ubuntu)
    -v, --version VERSION    Distribution version (e.g., 25.04, 24.04 for Ubuntu; 12, 11 for Debian)
    -c, --codename CODENAME  Distribution codename (e.g., plucky, noble, bookworm, bullseye)
                           Note: For Ubuntu/Debian, specify either --version OR --codename (the other will be derived)
    -a, --arch ARCH         Target architecture (default: amd64)
    -m, --mirror URL        Distribution mirror URL 
                           (default: archive.ubuntu.com for Ubuntu, deb.debian.org for Debian)
    --variant VARIANT       Debootstrap variant (default: minbase)
                           Options: essential, apt, required, minbase, buildd
    --docker-image IMAGE    Docker base image (default: ubuntu:latest)
    --preserve-hostid       Copy existing /etc/hostid from current system
                           Use this when updating an existing ZFS system
    --configure             Automatically configure the base image with Ansible
    --ansible-tags TAGS     Specific Ansible tags to run (comma-separated)
                           Example: --ansible-tags timezone,locale
    --verbose               Enable verbose output
    --dry-run               Show commands without executing
    --debug                 Enable debug output
    -h, --help              Show this help message

EXAMPLES:
    # Create Ubuntu 25.04 base system (specify version, codename derived)
    $0 --version 25.04 /mnt/base-system
    
    # Create Ubuntu base system (specify codename, version derived)  
    $0 --codename plucky /mnt/base-system
    
    # Create Debian 12 (specify version, codename derived)
    $0 --distribution debian --version 12 /mnt/base-system
    
    # Create with custom mirror
    $0 --version 24.04 --mirror http://gb.archive.ubuntu.com/ubuntu /mnt/base-system

TARGET_DIR:
    Directory where the base image will be created.
    Will be created if it doesn't exist.

EXAMPLES:
    # Create Ubuntu 24.04 LTS base image (specify version)
    $0 --version 24.04 /mnt/ubuntu-base

    # Create Ubuntu base image (specify codename) 
    $0 --codename noble /mnt/ubuntu-base

    # Create Debian 12 base image
    $0 --distribution debian --version 12 /mnt/debian-base

    # Update existing ZFS system - preserve current hostid
    $0 --version 24.04 --preserve-hostid /mnt/ubuntu-base

    # Create specific version with custom architecture
    $0 --version 24.04 --arch arm64 /mnt/ubuntu-arm64-base

    # Use custom mirror and rolling Docker image
    $0 --codename noble --mirror http://us.archive.ubuntu.com/ubuntu --docker-image ubuntu:rolling /mnt/ubuntu-base

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
    - Either --version OR --codename must be specified (for Ubuntu/Debian, the other will be derived)
EOF
}

# Function to create mmdebstrap command
create_mmdebstrap_cmd() {
    local target_path="/output"
    local base_packages
    
    # Set distribution-specific defaults
    case "$DISTRIBUTION" in
        ubuntu)
            base_packages="ca-certificates,ubuntu-keyring,systemd,init,linux-image-generic,zfsutils-linux,zfs-initramfs,apt,curl,wget"
            ;;
        debian)
            base_packages="ca-certificates,debian-archive-keyring,systemd,systemd-sysv,linux-image-amd64,zfsutils-linux,zfs-initramfs,apt,curl,wget"
            ;;
        *)
            # Generic defaults for other distributions
            base_packages="ca-certificates,systemd,linux-image-generic,zfsutils-linux,zfs-initramfs,apt,curl,wget"
            ;;
    esac
    
    # Use custom mirror if provided, otherwise use distribution default
    local mirror_url="${MIRROR:-${DIST_MIRRORS[$DISTRIBUTION]}}"
    
    cat << EOF
mmdebstrap \\
    --verbose \\
    --arch=$ARCH \\
    --variant=$VARIANT \\
    --include=$base_packages \\
    --customize-hook='if [ -x "\$1/usr/bin/apt-get" ]; then chroot "\$1" apt-get clean; fi' \\
    --customize-hook='rm -rf "\$1/var/lib/apt/lists/*"' \\
    --customize-hook='rm -rf "\$1/tmp/*"' \\
    --customize-hook='rm -rf "\$1/var/tmp/*"' \\
    --customize-hook='rm -rf "\$1/var/cache/apt/archives/*.deb"' \\
    --customize-hook='echo "grub-pc hold" | chroot "\$1" dpkg --set-selections 2>/dev/null || true' \\
    --customize-hook='echo "grub-pc-bin hold" | chroot "\$1" dpkg --set-selections 2>/dev/null || true' \\
    --customize-hook='echo "grub2-common hold" | chroot "\$1" dpkg --set-selections 2>/dev/null || true' \\
    --customize-hook='echo "grub-common hold" | chroot "\$1" dpkg --set-selections 2>/dev/null || true' \\
    --customize-hook='chroot "\$1" apt-mark hold grub-pc grub-pc-bin grub2-common grub-common 2>/dev/null || true' \\
    $CODENAME \\
    $target_path \\
    $mirror_url
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
    
    log "Creating $DISTRIBUTION $VERSION base image in $abs_target_dir"
    
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
            apt-get install -y mmdebstrap wget gnupg
            
            echo 'Creating $DISTRIBUTION $VERSION ($CODENAME) base image...'
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
            log "Successfully created ZFS-ready $DISTRIBUTION base image:"
            log "  Directory: $abs_target_dir"
            log "  Size: $size"
            log "  Version: $DISTRIBUTION $VERSION ($CODENAME)"
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

# Function to configure the base image with Ansible
configure_base_image() {
    local abs_target_dir
    abs_target_dir=$(realpath "$TARGET_DIR")
    
    log "Configuring base image with Ansible..."
    
    # Get script directory and paths
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local ansible_dir="$script_dir/../ansible"
    local configure_script="$script_dir/configure-system.sh"
    
    if [[ ! -d "$ansible_dir" ]]; then
        log "ERROR: Ansible directory not found at $ansible_dir"
        log "Please ensure the ansible/ directory exists in the project root"
        exit 1
    fi
    
    # Check if configure-system.sh exists in scripts directory
    if [[ ! -f "$configure_script" ]]; then
        log "ERROR: configure-system.sh not found at $configure_script"
        exit 1
    fi
    
    # Build the configure command
    local configure_cmd="$configure_script"
    
    if [[ -n "$ANSIBLE_TAGS" ]]; then
        configure_cmd+=" --tags $ANSIBLE_TAGS"
    fi
    
    if [[ "$VERBOSE" == true ]]; then
        configure_cmd+=" --verbose"
    fi
    
    configure_cmd+=" $abs_target_dir"
    
    log "Running: $configure_cmd"
    
    if [[ "$DRY_RUN" == false ]]; then
        run_cmd $configure_cmd
    else
        echo "DRY-RUN: $configure_cmd"
    fi
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -d|--distribution)
            DISTRIBUTION="$2"
            shift 2
            ;;
        -v|--version)
            VERSION="$2"
            shift 2
            ;;
        -c|--codename)
            CODENAME="$2"
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
        --configure)
            CONFIGURE=true
            shift
            ;;
        --ansible-tags)
            ANSIBLE_TAGS="$2"
            CONFIGURE=true  # Automatically enable configure if tags are specified
            shift 2
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --debug)
            DEBUG=true
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        -*)
            die "Unknown option $1. Use --help for usage information"
            ;;
        *)
            if [[ -z "$TARGET_DIR" ]]; then
                TARGET_DIR="$1"
            else
                die "Multiple target directories specified"
            fi
            shift
            ;;
    esac
done

# Validate arguments
require_arg "TARGET_DIR" "$TARGET_DIR"

# Require at least one of version or codename
if [[ -z "$VERSION" ]] && [[ -z "$CODENAME" ]]; then
    die "Either --version OR --codename is required
Examples:
  --version 25.04    (codename 'plucky' will be derived)
  --codename plucky  (version '25.04' will be derived)
  --version 12       (for Debian, codename 'bookworm' will be derived)"
fi

# Main execution
main() {
    log "Starting $DISTRIBUTION base image creation"
    
    check_docker
    validate_distribution_info "$DISTRIBUTION" "$VERSION" "$CODENAME"
    
    # Update our variables with the validated/derived values
    VERSION="$DERIVED_VERSION"
    CODENAME="$DERIVED_CODENAME"
    
    create_base_image
    
    # Configure the base image if requested
    if [[ "$CONFIGURE" == true ]]; then
        configure_base_image
    fi
    
    log "$DISTRIBUTION base image creation completed"
}

# Run main function
main
