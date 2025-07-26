#!/bin/bash
#
# ZFS Operations Library
#
# This library provides standardized ZFS operations for the Ubuntu ZFS installer.
# It consolidates common ZFS patterns, error handling, and validation logic.

# --- Prevent multiple sourcing ---
if [[ "${__ZFS_LIB_LOADED:-}" == "true" ]]; then
    return 0
fi
readonly __ZFS_LIB_LOADED="true"

# ==============================================================================
# ZFS DATASET OPERATIONS
# ==============================================================================

# Check if a ZFS dataset exists
# Usage: zfs_dataset_exists "pool/dataset"
zfs_dataset_exists() {
    local dataset="$1"
    zfs list -H -o name "$dataset" &>/dev/null
}

# Get ZFS dataset property
# Usage: zfs_get_property "pool/dataset" "mountpoint"
zfs_get_property() {
    local dataset="$1"
    local property="$2"
    
    if ! zfs_dataset_exists "$dataset"; then
        return 1
    fi
    
    zfs get -H -o value "$property" "$dataset" 2>/dev/null
}

# Create ZFS dataset with error handling
# Usage: zfs_create_dataset "pool/dataset" [additional_options...]
zfs_create_dataset() {
    local dataset="$1"
    shift
    local options=("$@")
    
    log_debug "Creating ZFS dataset: $dataset"
    
    if zfs_dataset_exists "$dataset"; then
        log_warn "Dataset already exists: $dataset"
        return 0
    fi
    
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would create dataset: $dataset ${options[*]}"
        return 0
    fi
    
    if ! run_cmd zfs create "${options[@]}" "$dataset"; then
        die "Failed to create ZFS dataset: $dataset"
    fi
    
    log_debug "Successfully created dataset: $dataset"
}

# Destroy ZFS dataset with comprehensive cleanup
# Usage: zfs_destroy_dataset "pool/dataset" [--force]
zfs_destroy_dataset() {
    local dataset="$1"
    local force=false
    
    if [[ "${2:-}" == "--force" ]]; then
        force=true
    fi
    
    log_debug "Destroying ZFS dataset: $dataset (force=$force)"
    
    if ! zfs_dataset_exists "$dataset"; then
        log_warn "Dataset does not exist: $dataset"
        return 0
    fi
    
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would destroy dataset: $dataset"
        return 0
    fi
    
    local destroy_args=()
    if [[ "$force" == true ]]; then
        destroy_args+=("-f")
    fi
    destroy_args+=("-r")  # Always recursive to handle snapshots
    
    if ! run_cmd zfs destroy "${destroy_args[@]}" "$dataset"; then
        die "Failed to destroy ZFS dataset: $dataset"
    fi
    
    log_debug "Successfully destroyed dataset: $dataset"
}

# Mount ZFS dataset 
# Usage: zfs_mount_dataset "pool/dataset" "/mount/point"
zfs_mount_dataset() {
    local dataset="$1"
    local mount_point="$2"
    
    log_debug "Mounting ZFS dataset: $dataset -> $mount_point"
    
    if ! zfs_dataset_exists "$dataset"; then
        die "Cannot mount non-existent dataset: $dataset"
    fi
    
    # Create mount point if it doesn't exist
    if [[ ! -d "$mount_point" ]]; then
        if [[ "$DRY_RUN" == true ]]; then
            log_info "[DRY RUN] Would create mount point: $mount_point"
        else
            if ! mkdir -p "$mount_point"; then
                die "Failed to create mount point: $mount_point"
            fi
        fi
    fi
    
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would mount: $dataset -> $mount_point"
        return 0
    fi
    
    if ! run_cmd mount -t zfs "$dataset" "$mount_point"; then
        die "Failed to mount ZFS dataset: $dataset -> $mount_point"
    fi
    
    log_debug "Successfully mounted dataset: $dataset -> $mount_point"
}

# Unmount ZFS dataset
# Usage: zfs_unmount_dataset "pool/dataset" [--force]
zfs_unmount_dataset() {
    local dataset="$1"
    local force=false
    
    if [[ "${2:-}" == "--force" ]]; then
        force=true
    fi
    
    log_debug "Unmounting ZFS dataset: $dataset (force=$force)"
    
    if ! zfs_dataset_exists "$dataset"; then
        log_warn "Dataset does not exist: $dataset"
        return 0
    fi
    
    # Get current mount point
    local mount_point
    mount_point=$(zfs_get_property "$dataset" "mountpoint")
    
    if [[ "$mount_point" == "none" || "$mount_point" == "legacy" ]]; then
        log_debug "Dataset not auto-mounted: $dataset"
        return 0
    fi
    
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would unmount: $dataset"
        return 0
    fi
    
    local umount_args=()
    if [[ "$force" == true ]]; then
        umount_args+=("-f")
    fi
    
    if ! run_cmd umount "${umount_args[@]}" "$mount_point"; then
        log_warn "Failed to unmount dataset: $dataset from $mount_point"
        return 1
    fi
    
    log_debug "Successfully unmounted dataset: $dataset"
}

# Set ZFS dataset property
# Usage: zfs_set_property "pool/dataset" "property=value"
zfs_set_property() {
    local dataset="$1"
    local property="$2"
    
    log_debug "Setting ZFS property: $dataset $property"
    
    if ! zfs_dataset_exists "$dataset"; then
        die "Cannot set property on non-existent dataset: $dataset"
    fi
    
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would set property: $dataset $property"
        return 0
    fi
    
    if ! run_cmd zfs set "$property" "$dataset"; then
        die "Failed to set ZFS property: $dataset $property"
    fi
    
    log_debug "Successfully set property: $dataset $property"
}

# List ZFS datasets with filtering
# Usage: zfs_list_datasets "pool/ROOT" [type] [depth]
zfs_list_datasets() {
    local parent="${1:-}"
    local type="${2:-filesystem}"
    local depth="${3:-1}"
    
    local list_args=("-H" "-o" "name,used,mountpoint,mounted" "-t" "$type")
    
    if [[ -n "$parent" ]]; then
        list_args+=("-r" "-d" "$depth" "$parent")
    fi
    
    zfs list "${list_args[@]}" 2>/dev/null || true
}

# ==============================================================================
# ZFS SNAPSHOT OPERATIONS 
# ==============================================================================

# Check if a ZFS snapshot exists
# Usage: zfs_snapshot_exists "pool/dataset@snapshot"
zfs_snapshot_exists() {
    local snapshot="$1"
    zfs list -t snapshot "$snapshot" >/dev/null 2>&1
}

# Create ZFS snapshot with timestamp
# Usage: zfs_create_snapshot "pool/dataset" "snapshot-name"
zfs_create_snapshot() {
    local dataset="$1"
    local snapshot_name="$2"
    local timestamp="${3:-$(date +$SNAPSHOT_TIMESTAMP_FORMAT)}"
    
    local full_snapshot="${dataset}@${SNAPSHOT_PREFIX}-${snapshot_name}-${timestamp}"
    
    log_debug "Creating ZFS snapshot: $full_snapshot"
    
    if ! zfs_dataset_exists "$dataset"; then
        die "Cannot snapshot non-existent dataset: $dataset"
    fi
    
    if zfs_snapshot_exists "$full_snapshot"; then
        log_warn "Snapshot already exists: $full_snapshot"
        return 0
    fi
    
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would create snapshot: $full_snapshot"
        return 0
    fi
    
    if ! run_cmd zfs snapshot "$full_snapshot"; then
        die "Failed to create ZFS snapshot: $full_snapshot"
    fi
    
    log_info "Created snapshot: $full_snapshot"
    echo "$full_snapshot"
}

# Destroy ZFS snapshot
# Usage: zfs_destroy_snapshot "pool/dataset@snapshot"
zfs_destroy_snapshot() {
    local snapshot="$1"
    
    log_debug "Destroying ZFS snapshot: $snapshot"
    
    if ! zfs_snapshot_exists "$snapshot"; then
        log_warn "Snapshot does not exist: $snapshot"
        return 0
    fi
    
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would destroy snapshot: $snapshot"
        return 0
    fi
    
    if ! run_cmd zfs destroy "$snapshot"; then
        die "Failed to destroy ZFS snapshot: $snapshot"
    fi
    
    log_debug "Successfully destroyed snapshot: $snapshot"
}

# Rollback to ZFS snapshot
# Usage: zfs_rollback_snapshot "pool/dataset@snapshot" [--force]
zfs_rollback_snapshot() {
    local snapshot="$1"
    local force=false
    
    if [[ "${2:-}" == "--force" ]]; then
        force=true
    fi
    
    log_debug "Rolling back to ZFS snapshot: $snapshot (force=$force)"
    
    if ! zfs_snapshot_exists "$snapshot"; then
        die "Cannot rollback to non-existent snapshot: $snapshot"
    fi
    
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would rollback to snapshot: $snapshot"
        return 0
    fi
    
    local rollback_args=()
    if [[ "$force" == true ]]; then
        rollback_args+=("-f")
    fi
    rollback_args+=("-r")  # Recursive rollback
    
    if ! run_cmd zfs rollback "${rollback_args[@]}" "$snapshot"; then
        die "Failed to rollback to ZFS snapshot: $snapshot"
    fi
    
    log_info "Successfully rolled back to snapshot: $snapshot"
}

# List ZFS snapshots for a dataset
# Usage: zfs_list_snapshots "pool/dataset" [pattern]
zfs_list_snapshots() {
    local dataset="$1"
    local pattern="${2:-}"
    
    local list_args=("-t" "snapshot" "-o" "name" "-S" "creation" "-H" "$dataset")
    
    local snapshots
    snapshots=($(zfs list "${list_args[@]}" 2>/dev/null))
    
    if [[ -n "$pattern" ]]; then
        printf '%s\n' "${snapshots[@]}" | grep "$pattern" || true
    else
        printf '%s\n' "${snapshots[@]}"
    fi
}

# Cleanup old snapshots beyond retention count
# Usage: zfs_cleanup_old_snapshots "pool/dataset" "snapshot-pattern" [keep_count]
zfs_cleanup_old_snapshots() {
    local dataset="$1"
    local pattern="$2"
    local keep_count="${3:-$SNAPSHOT_RETAIN_COUNT}"
    
    log_debug "Cleaning up old snapshots for $dataset (pattern: $pattern, keep: $keep_count)"
    
    local snapshots
    snapshots=($(zfs_list_snapshots "$dataset" "$pattern"))
    
    if [[ ${#snapshots[@]} -le $keep_count ]]; then
        log_debug "Only ${#snapshots[@]} snapshots found, no cleanup needed"
        return 0
    fi
    
    local to_remove=("${snapshots[@]:$keep_count}")
    
    for snapshot in "${to_remove[@]}"; do
        log_info "Removing old snapshot: $snapshot"
        zfs_destroy_snapshot "$snapshot"
    done
    
    log_info "Cleaned up ${#to_remove[@]} old snapshots"
}

# ==============================================================================
# ZFS POOL OPERATIONS
# ==============================================================================

# Check if ZFS pool exists and is healthy
# Usage: zfs_check_pool "poolname"
zfs_check_pool() {
    local pool_name="$1"
    
    log_debug "Checking ZFS pool: $pool_name"
    
    if ! zpool list -H -o name "$pool_name" &>/dev/null; then
        local available_pools
        available_pools=$(zpool list -H -o name 2>/dev/null | sed 's/^/    /' | tr '\n' ' ')
        
        die_with_context \
            "ZFS pool '$pool_name' not found" \
            "Available pools:${available_pools:- None}. Create a pool with: sudo zpool create $pool_name <device>" \
            "$EXIT_CONFIG_ERROR"
    fi
    
    # Check pool health
    local pool_health
    pool_health=$(zpool list -H -o health "$pool_name" 2>/dev/null)
    if [[ "$pool_health" != "ONLINE" ]]; then
        log_warn "⚠️  ZFS pool '$pool_name' status: $pool_health"
        log_info "💡 Check pool status with: sudo zpool status $pool_name"
    else
        log_debug "✓ ZFS pool '$pool_name' is healthy (ONLINE)"
    fi
}

# Get ZFS pool property
# Usage: zfs_get_pool_property "poolname" "property"
zfs_get_pool_property() {
    local pool_name="$1"
    local property="$2"
    
    zpool get -H -o value "$property" "$pool_name" 2>/dev/null
}

# ==============================================================================
# HIGH-LEVEL ZFS OPERATIONS
# ==============================================================================

# Create a complete ZFS root dataset structure
# Usage: zfs_create_root_dataset "pool" "build-name"
zfs_create_root_dataset() {
    local pool="$1"
    local build_name="$2"
    
    log_info "Creating ZFS root dataset structure for: $build_name"
    
    local root_parent="${pool}/ROOT"
    local dataset="${root_parent}/${build_name}"
    local varlog_dataset="${dataset}/varlog"
    
    # Ensure ROOT parent exists
    if ! zfs_dataset_exists "$root_parent"; then
        zfs_create_dataset "$root_parent" \
            "-o" "canmount=off" \
            "-o" "mountpoint=none"
    fi
    
    # Create main dataset
    zfs_create_dataset "$dataset" \
        "-o" "canmount=$DATASET_CANMOUNT" \
        "-o" "mountpoint=$DATASET_MOUNTPOINT"
    
    # Create varlog dataset
    zfs_create_dataset "$varlog_dataset" \
        "-o" "mountpoint=$DATASET_MOUNTPOINT"
    
    log_info "Successfully created ZFS root dataset: $dataset"
}

# Mount ZFS root dataset to build area
# Usage: zfs_mount_root_dataset "pool" "build-name" [mount-base]
zfs_mount_root_dataset() {
    local pool="$1"
    local build_name="$2"
    local mount_base="${3:-$DEFAULT_MOUNT_BASE}"
    
    local dataset
    dataset=$(zfs_get_root_dataset_path "$pool" "$build_name")
    local mount_point="${mount_base}/${build_name}"
    
    log_info "Mounting ZFS root dataset: $dataset -> $mount_point"
    
    # Mount main dataset
    zfs_mount_dataset "$dataset" "$mount_point"
    
    # Mount varlog if it exists
    local varlog_dataset="${dataset}/varlog"
    if zfs_dataset_exists "$varlog_dataset"; then
        local varlog_mount="${mount_point}/var/log"
        mkdir -p "$varlog_mount"
        zfs_mount_dataset "$varlog_dataset" "$varlog_mount"
    fi
    
    log_info "Successfully mounted root dataset at: $mount_point"
}

# Promote ZFS dataset to be bootable
# Usage: zfs_promote_to_bootfs "pool" "build-name"
zfs_promote_to_bootfs() {
    local pool="$1"
    local build_name="$2"
    
    local dataset
    dataset=$(zfs_get_root_dataset_path "$pool" "$build_name")
    
    log_info "Promoting dataset to bootfs: $dataset"
    
    if ! zfs_dataset_exists "$dataset"; then
        die "Cannot promote non-existent dataset: $dataset"
    fi
    
    # Set as bootfs
    zfs_set_property "$pool" "bootfs=$dataset"
    
    # Set canmount property
    zfs_set_property "$dataset" "canmount=noauto"
    
    log_info "Successfully promoted dataset to bootfs: $dataset"
}

# ==============================================================================
# HIGH-LEVEL ROOT DATASET OPERATIONS
# ==============================================================================

# Get standardized root dataset path
# Usage: zfs_get_root_dataset_path "pool" "build-name"
zfs_get_root_dataset_path() {
    local pool="$1"
    local build_name="$2"
    echo "${pool}/${DEFAULT_ROOT_DATASET}/${build_name}"
}

# Get varlog dataset path
# Usage: zfs_get_varlog_dataset_path "pool" "build-name"
zfs_get_varlog_dataset_path() {
    local pool="$1"
    local build_name="$2"
    echo "$(zfs_get_root_dataset_path "$pool" "$build_name")/varlog"
}

# Check if root dataset exists
# Usage: zfs_root_dataset_exists "pool" "build-name"
zfs_root_dataset_exists() {
    local pool="$1" 
    local build_name="$2"
    local dataset
    dataset=$(zfs_get_root_dataset_path "$pool" "$build_name")
    zfs_dataset_exists "$dataset"
}

# List all root datasets in a pool
# Usage: zfs_list_root_datasets "pool"
zfs_list_root_datasets() {
    local pool="$1"
    local root_parent="${pool}/${DEFAULT_ROOT_DATASET}"
    
    # Check if ROOT dataset exists
    if ! zfs_dataset_exists "$root_parent"; then
        return 1
    fi
    
    # List direct children of ROOT dataset, excluding ROOT itself
    zfs list -r -d 1 -t filesystem -o name,used,mountpoint,mounted -p -H "${root_parent}" 2>/dev/null | \
        grep -v "^${root_parent}[[:space:]]"
}

# Destroy a root dataset and all its snapshots
# Usage: zfs_destroy_root_dataset "pool" "build-name"
zfs_destroy_root_dataset() {
    local pool="$1"
    local build_name="$2"
    local dataset
    dataset=$(zfs_get_root_dataset_path "$pool" "$build_name")
    
    log_info "Destroying root dataset and all snapshots: $dataset"
    zfs_destroy_dataset "$dataset" --force
}

# Check if varlog dataset exists for a build
# Usage: zfs_varlog_dataset_exists "pool" "build-name"
zfs_varlog_dataset_exists() {
    local pool="$1"
    local build_name="$2"
    local varlog_dataset
    varlog_dataset=$(zfs_get_varlog_dataset_path "$pool" "$build_name")
    zfs_dataset_exists "$varlog_dataset"
}
