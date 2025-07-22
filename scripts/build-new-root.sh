#!/bin/bash

# Multi-Distribution ZFS Root Builder - Orchestrates the complete build process
# Usage: ./build-new-root.sh [OPTIONS] BUILD_NAME HOSTNAME

set -euo pipefail

# Get script directory for sourcing
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common library
source "$script_dir/../lib/common.sh"

# Default values
BUILD_NAME=""
HOSTNAME=""
DISTRIBUTION="${DEFAULT_DISTRIBUTION}"
VERSION=""
CODENAME=""
ARCH="${DEFAULT_ARCH}"
POOL_NAME="${DEFAULT_POOL_NAME}"
ANSIBLE_TAGS=""
ANSIBLE_LIMIT=""
CLEANUP=false

# Function to show usage
show_help() {
    cat << EOF
Usage: $0 [OPTIONS] BUILD_NAME HOSTNAME

Complete multi-distribution ZFS root builder - orchestrates the entire process from
ZFS dataset creation through base OS installation to Ansible configuration.

ARGUMENTS:
    BUILD_NAME              Name for this build (e.g., ubuntu-25.04, debian-12, server-build)
    HOSTNAME                Target hostname (must have corresponding host_vars file)

OPTIONS:
    -d, --distribution DIST Distribution to build (default: ubuntu)
    -v, --version VERSION   Distribution version (e.g., 25.04, 24.04, 12, 11)
    -c, --codename CODENAME Distribution codename (e.g., plucky, noble, bookworm)
                           Note: For Ubuntu/Debian, specify either --version OR --codename
    -a, --arch ARCH         Target architecture (default: amd64)
    -p, --pool POOL         ZFS pool to use (default: zroot)
    -t, --tags TAGS         Ansible tags to run (comma-separated)
    -l, --limit PATTERN     Ansible limit pattern (default: HOSTNAME)
    --cleanup               Remove existing build with same name
    --verbose               Enable verbose output
    --dry-run               Show commands without executing
    --debug                 Enable debug output
    -h, --help              Show this help message

EXAMPLES:
    # Build Ubuntu 25.04 system for blackbox
    $0 --version 25.04 ubuntu-25.04 blackbox

    # Build with codename and cleanup existing
    $0 --cleanup --codename noble --verbose ubuntu-server myserver

    # Build only base system (no Ansible configuration)
    $0 --version 24.04 --tags never ubuntu-minimal minimal-host

    # Build Debian 12 system
    $0 --distribution debian --version 12 debian-12 myhost

    # Dry run to see what would happen
    $0 --dry-run --verbose --codename plucky ubuntu-test testhost

PROCESS:
    1. Create ZFS datasets and mount points
    2. Install base OS image with mmdebstrap  
    3. Configure system with Ansible
    4. Report final mount points and next steps

REQUIREMENTS:
    - config/host_vars/HOSTNAME.yml must exist
    - ZFS pool must exist and be accessible
    - Docker must be installed for base OS installation
    - Sufficient space in ZFS pool for system image

OUTPUT LOCATIONS:
    Base system:    /var/tmp/zfs-builds/BUILD_NAME
    Var/log:        /var/tmp/zfs-builds/BUILD_NAME/var/log
EOF
}

# Function to check prerequisites
check_prerequisites() {
    local hostname="$1"
    
    # Check for required scripts
    local required_scripts=(
        "create-zfs-datasets.sh"
        "install-base-os.sh"
        "configure-system.sh"
    )
    
    for script in "${required_scripts[@]}"; do
        if [[ ! -x "$script_dir/$script" ]]; then
            die "Required script not found or not executable: $script_dir/$script"
        fi
    done
    
    # Check for host configuration
    local host_vars_file="$script_dir/../config/host_vars/$hostname.yml"
    if [[ ! -f "$host_vars_file" ]]; then
        log_error "Host configuration not found: $host_vars_file"
        log "Available hosts:"
        ls -1 "$script_dir/../config/host_vars/"*.yml 2>/dev/null | xargs -I {} basename {} .yml | sed 's/^/  /' || log "  None found"
        exit 1
    fi
    
    # Check ZFS pool
    check_zfs_pool "$POOL_NAME"
    
    # Check Docker
    check_docker
    
    if ! docker info >/dev/null 2>&1; then
        log "ERROR: Docker is not running or not accessible"
        exit 1
    fi
    
    log "Prerequisites check passed"
}

# Function to create build environment
create_build_env() {
    # If cleanup is requested, first remove existing datasets
    if [[ "$CLEANUP" == true ]]; then
        local cleanup_cmd="$script_dir/create-zfs-datasets.sh --cleanup"
        
        if [[ "$VERBOSE" == true ]]; then
            cleanup_cmd+=" --verbose"
        fi
        
        if [[ "$DRY_RUN" == true ]]; then
            cleanup_cmd+=" --dry-run"
        fi
        
        if [[ "$DEBUG" == true ]]; then
            cleanup_cmd+=" --debug"
        fi
        
        cleanup_cmd+=" --pool $POOL_NAME"
        cleanup_cmd+=" $CODENAME"
        
        log "Removing existing ZFS datasets..."
        run_cmd $cleanup_cmd
    fi
    
    # Now create the datasets (always, whether cleanup was done or not)
    local cmd="$script_dir/create-zfs-datasets.sh --no-varlog"
    
    if [[ "$VERBOSE" == true ]]; then
        cmd+=" --verbose"
    fi
    
    if [[ "$DRY_RUN" == true ]]; then
        cmd+=" --dry-run"
    fi
    
    if [[ "$DEBUG" == true ]]; then
        cmd+=" --debug"
    fi
    
    cmd+=" --pool $POOL_NAME"
    cmd+=" $CODENAME"
    
    log "Creating ZFS datasets..."
    run_cmd $cmd
}

# Function to create base system
create_base_system() {
    local target_dir="/var/tmp/zfs-builds/$CODENAME"
    local cmd="$script_dir/install-base-os.sh"
    
    # Require at least version or codename
    if [[ -z "$VERSION" ]] && [[ -z "$CODENAME" ]]; then
        log "ERROR: Either --version or --codename is required for base system creation"
        exit 1
    fi
    
    cmd+=" --distribution $DISTRIBUTION"
    
    if [[ -n "$VERSION" ]]; then
        cmd+=" --version $VERSION"
    fi
    
    if [[ -n "$CODENAME" ]]; then
        cmd+=" --codename $CODENAME"
    fi
    
    if [[ "$ARCH" != "amd64" ]]; then
        cmd+=" --arch $ARCH"
    fi
    
    if [[ "$VERBOSE" == true ]]; then
        cmd+=" --verbose"
    fi
    
    if [[ "$DRY_RUN" == true ]]; then
        cmd+=" --dry-run"
    fi
    
    if [[ "$DEBUG" == true ]]; then
        cmd+=" --debug"
    fi
    
    cmd+=" $target_dir"
    
    log "Installing base OS image..."
    run_cmd $cmd
}

# Function to mount varlog after base OS creation
mount_varlog() {
    local cmd="$script_dir/create-zfs-datasets.sh --mount-varlog"
    
    if [[ "$VERBOSE" == true ]]; then
        cmd+=" --verbose"
    fi
    
    if [[ "$DRY_RUN" == true ]]; then
        cmd+=" --dry-run"
    fi
    
    if [[ "$DEBUG" == true ]]; then
        cmd+=" --debug"
    fi
    
    cmd+=" --pool $POOL_NAME"
    cmd+=" $CODENAME"
    
    log "Mounting varlog dataset..."
    run_cmd $cmd
}

# Function to configure system
configure_system() {
    local target_dir="/var/tmp/zfs-builds/$CODENAME"
    local cmd="$script_dir/configure-system.sh"
    
    if [[ -n "$ANSIBLE_TAGS" ]]; then
        cmd+=" --tags $ANSIBLE_TAGS"
    fi
    
    if [[ -n "$ANSIBLE_LIMIT" ]]; then
        cmd+=" --limit $ANSIBLE_LIMIT"
    else
        # Default to the hostname
        cmd+=" --limit $HOSTNAME"
    fi
    
    if [[ "$VERBOSE" == true ]]; then
        cmd+=" --verbose"
    fi
    
    if [[ "$DRY_RUN" == true ]]; then
        cmd+=" --dry-run"
    fi
    
    if [[ "$DEBUG" == true ]]; then
        cmd+=" --debug"
    fi
    
    cmd+=" $target_dir"
    
    # Skip configuration if tags is "never" (allows base-only builds)
    if [[ "$ANSIBLE_TAGS" == "never" ]]; then
        log "Skipping Ansible configuration (tags=never)"
        return 0
    fi
    
    log "Configuring system with Ansible..."
    run_cmd $cmd
}

# Function to show completion summary
show_completion() {
    local base_mount="/var/tmp/zfs-builds/$CODENAME"
    local varlog_mount="/var/tmp/zfs-builds/$CODENAME/var/log"
    
    echo
    log "=== BUILD COMPLETED SUCCESSFULLY ==="
    echo
    log "Build name:       $BUILD_NAME"
    log "Hostname:         $HOSTNAME"
    log "Distribution:     $DISTRIBUTION"
    log "Architecture:     $ARCH"
    echo
    log "Mount points:"
    log "  Root:           $base_mount"
    log "  Var/log:        $varlog_mount"
    echo
    log "ZFS datasets created:"
    log "  zroot/ROOT/$CODENAME        -> $base_mount"
    log "  zroot/ROOT/$CODENAME/varlog -> $varlog_mount"
    echo
    log "Next steps:"
    log "  1. Test the system: sudo systemd-nspawn --directory=$base_mount"
    log "  2. Create snapshot: zfs snapshot zroot/ROOT/$CODENAME@ready"
    log "  3. When ready to deploy: zfs set mountpoint=/ zroot/ROOT/$CODENAME"
    log "  4. Reboot and select this boot environment from GRUB"
    echo
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
        -p|--pool)
            POOL_NAME="$2"
            shift 2
            ;;
        -t|--tags)
            ANSIBLE_TAGS="$2"
            shift 2
            ;;
        -l|--limit)
            ANSIBLE_LIMIT="$2"
            shift 2
            ;;
        --cleanup)
            CLEANUP=true
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
        --debug)
            DEBUG=true
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            # Arguments should be BUILD_NAME and HOSTNAME
            if [[ -z "$BUILD_NAME" ]]; then
                BUILD_NAME="$1"
                shift
            elif [[ -z "$HOSTNAME" ]]; then
                HOSTNAME="$1"
                shift
            else
                die "Unknown option $1. Use --help for usage information"
            fi
            ;;
    esac
done

# Validate required arguments
require_arg "BUILD_NAME" "$BUILD_NAME"
require_arg "HOSTNAME" "$HOSTNAME"

# Validate build name
if [[ ! "$BUILD_NAME" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    die "BUILD_NAME must contain only letters, numbers, dots, dashes, and underscores"
fi

# Validate distribution info and derive missing version/codename
validate_distribution_info "$DISTRIBUTION" "$VERSION" "$CODENAME"

# Update our variables with the validated/derived values
VERSION="$DERIVED_VERSION"
CODENAME="$DERIVED_CODENAME"

# Show what we're going to do
    log "Multi-Distribution ZFS Root Builder"
    log "============================="
log "Build name:       $BUILD_NAME"
log "Hostname:         $HOSTNAME"
log "Distribution:     $DISTRIBUTION"
log "Version:          $VERSION ($CODENAME)"
log "Architecture:     $ARCH"
log "ZFS pool:         $POOL_NAME"
log "Ansible tags:     ${ANSIBLE_TAGS:-all}"
log "Cleanup existing: $CLEANUP"
echo

# Check prerequisites
if [[ "$DRY_RUN" == false ]]; then
    check_prerequisites "$HOSTNAME"
fi

# Execute build process
log "Starting build process..."

# Step 1: Create build environment
create_build_env

# Step 2: Create base system
create_base_system

# Step 3: Mount varlog dataset (after base OS creation)
mount_varlog

# Step 4: Configure system
configure_system

# Step 5: Show completion summary
if [[ "$DRY_RUN" == false ]]; then
    show_completion
else
    log "DRY-RUN completed - no changes made"
fi
