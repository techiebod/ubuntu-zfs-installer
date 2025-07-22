#!/bin/bash

# Script to create ZFS datasets for distribution boot environments
# Usage: ./create-zfs-datasets.sh [OPTIONS] CODENAME

set -euo pipefail

# Source common library
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/../lib/common.sh"

# Default values
CODENAME=""
DISTRIBUTION="$DEFAULT_DISTRIBUTION"
VERSION=""
POOL_NAME="$DEFAULT_POOL_NAME"
MOUNT_BASE="$DEFAULT_MOUNT_BASE"
CLEANUP=false
LIST_BUILDS=false
NO_VARLOG=false

# Function to show usage
show_help() {
    cat << EOF
Usage: $0 [OPTIONS] CODENAME

Create ZFS datasets for distribution boot environments following the existing ROOT pattern.
Creates datasets: {pool}/ROOT/{codename} and {pool}/ROOT/{codename}/varlog

ARGUMENTS:
    CODENAME                Distribution codename (e.g., plucky, noble, jammy, bookworm)
                           Will be validated against real distribution releases

OPTIONS:
    -d, --distribution DIST Distribution (default: $DEFAULT_DISTRIBUTION)
    -p, --pool POOL         ZFS pool to use (default: $DEFAULT_POOL_NAME)
    -m, --mount-base PATH   Base mount point (default: $DEFAULT_MOUNT_BASE)
    -c, --cleanup           Remove existing build with same codename
    -l, --list              List existing datasets and exit
    --mount-varlog          Mount varlog dataset for existing build (after base OS creation)
    --no-varlog             Create datasets but don't mount varlog initially (useful for mmdebstrap)
    -v, --verbose           Enable verbose output
    --dry-run               Show commands without executing
    --debug                 Enable debug output
    -h, --help              Show this help message

EXAMPLES:
    # Create new build environment datasets (example: plucky for Ubuntu 25.04)
    $0 plucky

    # Create datasets in different pool
    $0 --pool tank noble

    # Clean up and recreate existing datasets
    $0 --cleanup --verbose plucky

    # List all existing ZFS datasets
    $0 --list

DATASETS CREATED:
    {pool}/ROOT/{codename}         -> {mount-base}/{codename}
    {pool}/ROOT/{codename}/varlog  -> {mount-base}/{codename}/var/log

EXAMPLE OUTPUT:
    For: $0 plucky
    Creates:
        zroot/ROOT/plucky        -> /var/tmp/zfs-builds/plucky
        zroot/ROOT/plucky/varlog -> /var/tmp/zfs-builds/plucky/var/log

WORKFLOW:
    1. Run this script to create ZFS datasets and mount points
    2. Use mount point for install-base-os.sh target
    3. Use mount point for Ansible configuration
    4. When satisfied, reboot and select new boot environment
EOF
}

# Note: Using common.sh functions for logging, command execution, and pool checking

list_builds() {
    local root_dataset="$POOL_NAME/ROOT"
    
    echo "Existing ZFS boot environments:"
    
    if ! zfs list -H -o name "$root_dataset" >/dev/null 2>&1; then
        echo "  No ROOT dataset found ($root_dataset does not exist)"
        return 0
    fi
    
    # Get the current bootfs property
    local current_bootfs=$(zpool get -H -o value bootfs "$POOL_NAME" 2>/dev/null || echo "")
    
    # Get what's actually mounted as root
    local actual_root_mount=$(mount | grep "on / " | awk '{print $1}' | head -1)
    
    # Get pool available space
    local pool_avail=$(zpool list -H -o size,alloc,free "$POOL_NAME" 2>/dev/null | awk '{print $3}')
    
    # List child datasets (boot environments) - exclude varlog datasets
    local builds=$(zfs list -H -r -o name,mountpoint,used "$root_dataset" 2>/dev/null | grep "^$root_dataset/" | awk '$1 !~ /\/varlog$/' || true)
    
    # Check for datasets with unexpected mountpoints for boot environments (exclude varlog datasets)
    local unexpected_mounts=$(zfs list -H -r -o name,mountpoint "$root_dataset" 2>/dev/null | grep "^$root_dataset/" | awk '$1 !~ /\/varlog$/' | while IFS=$'\t' read -r name mountpoint; do
        [[ -z "$name" ]] && continue
        # Boot environments should typically have mountpoint=/ or legacy (for builds)
        # Anything else might be misconfigured
        if [[ "$mountpoint" != "/" && "$mountpoint" != "legacy" && "$mountpoint" != "none" ]]; then
            echo "$name:$mountpoint"
        fi
    done || true)
    
    if [[ -n "$unexpected_mounts" ]]; then
        echo "WARNING: Found datasets with non-standard mountpoints for boot environments:"
        while IFS=: read -r dataset mountpoint; do
            [[ -n "$dataset" ]] && echo "  $dataset -> $mountpoint"
        done <<< "$unexpected_mounts"
        echo "  Boot environments typically use '/' (installed) or 'legacy' (build-in-progress)"
        echo
    fi
    
    if [[ -z "$builds" ]]; then
        echo "  No boot environments found"
        return 0
    fi
    
    echo
    printf "%-12s %-20s %-8s %-20s %s\n" "CODENAME" "MOUNT POINT" "USED" "STATUS" "VARLOG"
    printf "%-12s %-20s %-8s %-20s %s\n" "--------" "-----------" "----" "------" "------"
    
    while IFS=$'\t' read -r name mountpoint used; do
        # Skip varlog datasets - they are not boot environments
        if [[ "$name" =~ /varlog$ ]]; then
            continue
        fi
        
        # Extract codename from dataset path like zroot/ROOT/plucky
        local codename=$(echo "$name" | sed "s|^$root_dataset/||")
        local status=""
        local varlog_status=""
        
        # Check if varlog dataset exists and get its usage
        if zfs list -H -o used "$name/varlog" >/dev/null 2>&1; then
            varlog_status=$(zfs list -H -o used "$name/varlog" 2>/dev/null)
        else
            varlog_status="(none)"
        fi
        
        # Check status based on actual mount, bootfs, and mountpoint
        if [[ "$name" == "$actual_root_mount" ]]; then
            status="(current system)"
        elif [[ "$name" == "$current_bootfs" ]]; then
            status="(bootfs default)"
        elif [[ "$mountpoint" == "legacy" ]]; then
            status="(in-progress build)"
        elif [[ "$mountpoint" == "/" ]]; then
            status="(boot option)"
        else
            status="(unusual mountpoint)"
        fi
        
        printf "%-12s %-20s %-8s %-20s %s\n" "$codename" "$mountpoint" "$used" "$status" "$varlog_status"
    done <<< "$builds"
    
    echo
    if [[ -n "$current_bootfs" ]]; then
        echo "zpool bootfs: $current_bootfs"
    else
        echo "zpool bootfs: (not set)"
    fi
    if [[ -n "$actual_root_mount" ]]; then
        echo "Actually mounted as /: $actual_root_mount"
    fi
    if [[ -n "$pool_avail" ]]; then
        echo "Pool available space: $pool_avail"
    fi
    echo
}

# Function to mount varlog after base OS creation
mount_varlog() {
    local build_dataset="$POOL_NAME/ROOT/$CODENAME"
    local base_mount="$MOUNT_BASE/$CODENAME"
    local varlog_mount="$base_mount/var/log"
    local varlog_dataset="$build_dataset/varlog"
    
    # Verify the datasets exist
    if ! zfs list "$build_dataset" >/dev/null 2>&1; then
        echo "ERROR: Boot environment dataset does not exist: $build_dataset"
        exit 1
    fi
    
    if ! zfs list "$varlog_dataset" >/dev/null 2>&1; then
        echo "ERROR: Varlog dataset does not exist: $varlog_dataset"
        exit 1
    fi
    
    # Verify the base mount is mounted
    if ! mountpoint -q "$base_mount" 2>/dev/null; then
        echo "ERROR: Base mount point is not mounted: $base_mount"
        exit 1
    fi
    
    # Check if varlog is already mounted
    if mountpoint -q "$varlog_mount" 2>/dev/null; then
        echo "Varlog is already mounted at: $varlog_mount"
        return 0
    fi
    
    echo "Mounting varlog dataset for: $CODENAME"
    
    # Handle existing /var/log directory if it exists
    if [[ -d "$varlog_mount" ]] && [[ -n "$(ls -A "$varlog_mount" 2>/dev/null)" ]]; then
        echo "Existing /var/log directory found with content"
        echo "Moving existing logs to /var/log.old"
        run_cmd mv "$varlog_mount" "$base_mount/var/log.old"
    fi
    
    # Create the mount point and mount the varlog dataset
    run_cmd mkdir -p "$varlog_mount"
    run_cmd mount -t zfs "$varlog_dataset" "$varlog_mount"
    run_cmd chmod 755 "$varlog_mount"
    
    echo "Varlog mounted successfully!"
    echo "Mount points:"
    echo "  Root:     $base_mount"
    echo "  Var/log:  $varlog_mount"
    if [[ -d "$base_mount/var/log.old" ]]; then
        echo "  Old logs: $base_mount/var/log.old"
    fi
    echo
}

# Function to cleanup existing build
cleanup_build() {
    local build_dataset="$POOL_NAME/ROOT/$CODENAME"
    local base_mount="$MOUNT_BASE/$CODENAME"
    local varlog_mount="$base_mount/var/log"
    
    if zfs list "$build_dataset" >/dev/null 2>&1; then
        echo "Removing existing boot environment: $build_dataset"
        
        # Unmount legacy mounts if they exist
        if mountpoint -q "$varlog_mount" 2>/dev/null; then
            umount "$varlog_mount"
        fi
        if mountpoint -q "$base_mount" 2>/dev/null; then
            umount "$base_mount"
        fi
        
        # Destroy dataset and all children
        zfs destroy -r "$build_dataset"
        echo "Existing boot environment removed"
    else
        echo "No existing boot environment to cleanup: $build_dataset"
    fi
}

# Function to create build environment
create_build_environment() {
    local root_dataset="$POOL_NAME/ROOT"
    local build_dataset="$root_dataset/$CODENAME"
    local base_mount="$MOUNT_BASE/$CODENAME"
    local varlog_mount="$base_mount/var/log"
    
    echo "Creating boot environment: $CODENAME"
    
    # Create ROOT dataset if it doesn't exist
    if ! zfs list "$root_dataset" >/dev/null 2>&1; then
        echo "Creating ROOT dataset: $root_dataset"
        run_cmd zfs create "$root_dataset"
        run_cmd zfs set mountpoint=none "$root_dataset"
    fi
    
    # Create boot environment dataset
    if zfs list "$build_dataset" >/dev/null 2>&1; then
        # Check if this is an existing mounted system (not just a legacy build)
        local existing_mountpoint=$(zfs get -H -o value mountpoint "$build_dataset" 2>/dev/null)
        if [[ "$existing_mountpoint" != "legacy" ]]; then
            echo "ERROR: Boot environment '$CODENAME' already exists as an installed system"
            echo "Dataset: $build_dataset (mounted at: $existing_mountpoint)"
            echo "Cannot overwrite an installed system. Choose a different codename."
            exit 1
        else
            echo "ERROR: Boot environment '$CODENAME' already exists as an in-progress build"
            echo "Use --cleanup to remove existing build first"
            exit 1
        fi
    fi
    
    echo "Creating boot environment dataset: $build_dataset"
    run_cmd zfs create "$build_dataset"
    run_cmd zfs set mountpoint=legacy "$build_dataset"
    
    # Create separate /var/log dataset (allows independent log retention policies,
    # easier log rotation, and prevents logs from filling up the root filesystem)
    echo "Creating varlog dataset: $build_dataset/varlog"
    run_cmd zfs create "$build_dataset/varlog"
    run_cmd zfs set mountpoint=legacy "$build_dataset/varlog"
    
    # Ensure base mount directory exists and is safe to use
    if [[ ! -d "$MOUNT_BASE" ]]; then
        echo "Creating base mount directory: $MOUNT_BASE"
        run_cmd mkdir -p "$MOUNT_BASE"
    fi
    
    # Check if mount point is already in use
    if mountpoint -q "$base_mount" 2>/dev/null; then
        echo "ERROR: Mount point already in use: $base_mount"
        echo "Something is already mounted there. Use a different mount base or cleanup first."
        exit 1
    fi
    
    # Ensure mount points exist and manually mount the legacy datasets
    run_cmd mkdir -p "$base_mount"
    run_cmd mount -t zfs "$build_dataset" "$base_mount"
    
    if [[ "$NO_VARLOG" == false ]]; then
        run_cmd mkdir -p "$varlog_mount"
        run_cmd mount -t zfs "$build_dataset/varlog" "$varlog_mount"
        
        # Set permissions
        run_cmd chmod 755 "$base_mount"
        run_cmd chmod 755 "$varlog_mount"
        
        echo "Boot environment created successfully!"
        echo
        echo "Mount points:"
        echo "  Root:     $base_mount"
        echo "  Var/log:  $varlog_mount"
    else
        # Set permissions
        run_cmd chmod 755 "$base_mount"
        
        echo "Boot environment created successfully!"
        echo
        echo "Mount points:"
        echo "  Root:     $base_mount"
        echo "  Var/log:  (not mounted - use --mount-varlog after base OS creation)"
    fi
    echo
    echo "ZFS datasets created with mountpoint=legacy for build safety"
    echo "Datasets will not auto-mount on reboot until mountpoint is changed"
    echo
    echo "Next steps:"
    echo "  1. Create base system:"
    echo "     ./scripts/install-base-os.sh --distribution ubuntu --version 24.04 $base_mount"
    echo "  2. Configure system:"
    echo "     ./scripts/configure-system.sh --limit your-hostname $base_mount"
    echo "  3. When ready to deploy: zfs set mountpoint=/ $build_dataset"
    echo "  4. When satisfied, reboot and select this boot environment from GRUB"
    echo
}

# Parse arguments
ACTION=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -d|--distribution)
            DISTRIBUTION="$2"
            shift 2
            ;;
        --list)
            ACTION="list"
            shift
            ;;
        --cleanup)
            ACTION="cleanup"
            shift
            ;;
        --mount-varlog)
            ACTION="mount-varlog"
            shift
            ;;
        --pool)
            POOL_NAME="$2"
            shift 2
            ;;
        --mount-base)
            MOUNT_BASE="$2"
            shift 2
            ;;
        --no-varlog)
            NO_VARLOG=true
            shift
            ;;
        -v|--verbose)
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
        --help|-h)
            show_help
            exit 0
            ;;
        *)
            if [[ -z "$CODENAME" ]]; then
                CODENAME="$1"
            else
                die "Unknown argument: $1"
            fi
            shift
            ;;
    esac
done

# Validate arguments
if [[ -z "$ACTION" ]] && [[ -z "$CODENAME" ]]; then
    die "Must specify either action (--list, --cleanup) or codename"
fi

if [[ "$ACTION" == "cleanup" ]] && [[ -z "$CODENAME" ]]; then
    die "--cleanup requires codename"
fi

# Check if pool exists
check_zfs_pool "$POOL_NAME"

# Main execution
case "$ACTION" in
    "list")
        list_builds
        ;;
    "cleanup")
        if [[ -n "$CODENAME" ]]; then
            cleanup_build "$CODENAME"
        else
            die "No codename specified for cleanup"
        fi
        ;;
    "mount-varlog")
        if [[ -n "$CODENAME" ]]; then
            mount_varlog
        else
            die "No codename specified for mount-varlog"
        fi
        ;;
    *)
        if [[ -n "$CODENAME" ]]; then
            # Validate codename using smart distribution validation
            validate_distribution_info "$DISTRIBUTION" "" "$CODENAME"
            
            # Update our variables with the validated/derived values
            VERSION="$DERIVED_VERSION"
            CODENAME="$DERIVED_CODENAME"
            
            log "Using $DISTRIBUTION $VERSION ($CODENAME)"
            
            # Check if codename conflicts with existing installed system
            potential_dataset="$POOL_NAME/ROOT/$CODENAME"
            if zfs list "$potential_dataset" >/dev/null 2>&1; then
                existing_mountpoint=$(zfs get -H -o value mountpoint "$potential_dataset" 2>/dev/null)
                if [[ "$existing_mountpoint" != "legacy" ]]; then
                    die "Codename '$CODENAME' conflicts with existing installed system
Dataset: $potential_dataset (mounted at: $existing_mountpoint)
Choose a different codename to avoid conflicts with live systems"
                fi
            fi
            
            create_build_environment
        else
            die "No action or codename specified"
        fi
        ;;
esac
