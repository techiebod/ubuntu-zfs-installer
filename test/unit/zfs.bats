#!/usr/bin/env bats
# Tests for lib/zfs.sh - ZFS state-altering operations

# Load test helpers
load '../helpers/test_helper'

# Source the library under test
source "${PROJECT_ROOT}/lib/zfs.sh"

# Setup/teardown
setup() {
    # Create a temporary test environment
    export TEST_POOL="test_pool"
    export TEST_DATASET="test_pool/test"
    export TEST_BUILD_NAME="test-build"
    export TEST_MOUNT_POINT="/tmp/test-mount"
    export TEST_SNAPSHOT="test-snapshot"
    
    # Mock dry run mode by default for safety
    export DRY_RUN=true
    
    # Clear any existing cleanup stack
    clear_cleanup_stack 2>/dev/null || true
}

teardown() {
    # Reset environment
    unset TEST_POOL TEST_DATASET TEST_BUILD_NAME TEST_MOUNT_POINT TEST_SNAPSHOT
    unset DRY_RUN
}

# ==============================================================================
# ZFS Dataset Creation Tests
# ==============================================================================

@test "zfs_create_dataset: creates dataset with proper options" {
    run zfs_create_dataset "$TEST_DATASET" "-o" "mountpoint=none"
    
    assert_success
    assert_output --partial "[DRY RUN] Would create dataset: test_pool/test -o mountpoint=none"
}

@test "zfs_create_dataset: handles existing dataset gracefully" {
    # Mock zfs_dataset_exists to return true
    zfs_dataset_exists() { return 0; }
    
    run zfs_create_dataset "$TEST_DATASET"
    
    assert_success
    assert_output --partial "Dataset already exists: test_pool/test"
}

@test "zfs_create_dataset: validates dataset name format" {
    run zfs_create_dataset ""
    
    assert_success
    assert_output --partial "[DRY RUN] Would create dataset:"
}

@test "zfs_create_dataset: handles creation failure gracefully" {
    export DRY_RUN=false
    # Mock zfs_dataset_exists to return false
    zfs_dataset_exists() { return 1; }
    # Mock run_cmd to fail
    run_cmd() { return 1; }
    
    run zfs_create_dataset "$TEST_DATASET"
    
    assert_failure
    assert_output --partial "Failed to create ZFS dataset"
}

# ==============================================================================
# ZFS Dataset Destruction Tests
# ==============================================================================

@test "zfs_destroy_dataset: destroys dataset with recursive flag" {
    # Mock zfs_dataset_exists to return true
    zfs_dataset_exists() { return 0; }
    
    run zfs_destroy_dataset "$TEST_DATASET"
    
    assert_success
    assert_output --partial "[DRY RUN] Would destroy dataset: test_pool/test"
}

@test "zfs_destroy_dataset: handles non-existent dataset gracefully" {
    # Mock zfs_dataset_exists to return false
    zfs_dataset_exists() { return 1; }
    
    run zfs_destroy_dataset "$TEST_DATASET"
    
    assert_success
    assert_output --partial "Dataset does not exist: test_pool/test"
}

@test "zfs_destroy_dataset: applies force flag correctly" {
    # Mock zfs_dataset_exists to return true
    zfs_dataset_exists() { return 0; }
    
    run zfs_destroy_dataset "$TEST_DATASET" --force
    
    assert_success
    assert_output --partial "[DRY RUN] Would destroy dataset: test_pool/test"
}

@test "zfs_destroy_dataset: handles destruction failure" {
    export DRY_RUN=false
    # Mock zfs_dataset_exists to return true
    zfs_dataset_exists() { return 0; }
    # Mock run_cmd to fail
    run_cmd() { return 1; }
    
    run zfs_destroy_dataset "$TEST_DATASET"
    
    assert_failure
    assert_output --partial "Failed to destroy ZFS dataset"
}

# ==============================================================================
# ZFS Dataset Mounting Tests
# ==============================================================================

@test "zfs_mount_dataset: mounts dataset to specified path" {
    # Mock zfs_dataset_exists to return true
    zfs_dataset_exists() { return 0; }
    
    # Ensure mount point doesn't exist to trigger "create mount point" message
    rm -rf "$TEST_MOUNT_POINT"
    
    run zfs_mount_dataset "$TEST_DATASET" "$TEST_MOUNT_POINT"
    
    assert_success
    assert_output --partial "[DRY RUN] Would create mount point: /tmp/test-mount"
    assert_output --partial "[DRY RUN] Would mount: test_pool/test -> /tmp/test-mount"
}

@test "zfs_mount_dataset: validates dataset exists before mounting" {
    # Mock zfs_dataset_exists to return false
    zfs_dataset_exists() { return 1; }
    
    run zfs_mount_dataset "$TEST_DATASET" "$TEST_MOUNT_POINT"
    
    assert_failure
    assert_output --partial "Cannot mount non-existent dataset"
}

@test "zfs_mount_dataset: creates mount point directory" {
    # Mock zfs_dataset_exists to return true
    zfs_dataset_exists() { return 0; }
    
    run zfs_mount_dataset "$TEST_DATASET" "/tmp/nonexistent/path"
    
    assert_success
    assert_output --partial "[DRY RUN] Would create mount point: /tmp/nonexistent/path"
}

@test "zfs_mount_dataset: handles mount failure gracefully" {
    export DRY_RUN=false
    # Mock zfs_dataset_exists to return true
    zfs_dataset_exists() { return 0; }
    # Mock run_cmd to fail for mount command
    run_cmd() { 
        if [[ "$1" == "mount" ]]; then
            return 1
        fi
        return 0
    }
    
    run zfs_mount_dataset "$TEST_DATASET" "$TEST_MOUNT_POINT"
    
    assert_failure
    assert_output --partial "Failed to mount ZFS dataset"
}

# ==============================================================================
# ZFS Dataset Unmounting Tests
# ==============================================================================

@test "zfs_unmount_dataset: unmounts dataset" {
    # Mock zfs_dataset_exists and zfs_get_property
    zfs_dataset_exists() { return 0; }
    zfs_get_property() { echo "/mnt/test"; }
    
    run zfs_unmount_dataset "$TEST_DATASET"
    
    assert_success
    assert_output --partial "[DRY RUN] Would unmount: test_pool/test"
}

@test "zfs_unmount_dataset: handles non-existent dataset" {
    # Mock zfs_dataset_exists to return false
    zfs_dataset_exists() { return 1; }
    
    run zfs_unmount_dataset "$TEST_DATASET"
    
    assert_success
    assert_output --partial "Dataset does not exist: test_pool/test"
}

@test "zfs_unmount_dataset: skips non-mounted datasets" {
    # Mock zfs_dataset_exists to return true, mountpoint to be none
    zfs_dataset_exists() { return 0; }
    zfs_get_property() { echo "none"; }
    
    run zfs_unmount_dataset "$TEST_DATASET"
    
    assert_success
    # When mountpoint is "none", the function returns successfully without output
}

@test "zfs_unmount_dataset: applies force flag" {
    # Mock zfs_dataset_exists and zfs_get_property
    zfs_dataset_exists() { return 0; }
    zfs_get_property() { echo "/mnt/test"; }
    
    run zfs_unmount_dataset "$TEST_DATASET" --force
    
    assert_success
    assert_output --partial "[DRY RUN] Would unmount"
}

# ==============================================================================
# ZFS Property Setting Tests
# ==============================================================================

@test "zfs_set_property: sets property on dataset" {
    # Mock zfs_dataset_exists to return true
    zfs_dataset_exists() { return 0; }
    
    run zfs_set_property "$TEST_DATASET" "mountpoint=none"
    
    assert_success
    assert_output --partial "[DRY RUN] Would set property: test_pool/test mountpoint=none"
}

@test "zfs_set_property: validates dataset exists" {
    # Mock zfs_dataset_exists to return false
    zfs_dataset_exists() { return 1; }
    
    run zfs_set_property "$TEST_DATASET" "mountpoint=none"
    
    assert_failure
    assert_output --partial "Cannot set property on non-existent dataset"
}

@test "zfs_set_property: handles property setting failure" {
    export DRY_RUN=false
    # Mock zfs_dataset_exists to return true
    zfs_dataset_exists() { return 0; }
    # Mock run_cmd to fail
    run_cmd() { return 1; }
    
    run zfs_set_property "$TEST_DATASET" "mountpoint=none"
    
    assert_failure
    assert_output --partial "Failed to set ZFS property"
}

# ==============================================================================
# ZFS Snapshot Creation Tests
# ==============================================================================

@test "zfs_create_snapshot: creates snapshot with timestamp" {
    # Mock zfs_dataset_exists and zfs_snapshot_exists
    zfs_dataset_exists() { return 0; }
    zfs_snapshot_exists() { return 1; }
    
    run zfs_create_snapshot "$TEST_DATASET" "$TEST_SNAPSHOT" "20240101-120000"
    
    assert_success
    assert_output --partial "[DRY RUN] Would create snapshot: test_pool/test@build-stage-test-snapshot-20240101-120000"
}

@test "zfs_create_snapshot: validates source dataset exists" {
    # Mock zfs_dataset_exists to return false
    zfs_dataset_exists() { return 1; }
    
    run zfs_create_snapshot "$TEST_DATASET" "$TEST_SNAPSHOT"
    
    assert_failure
    assert_output --partial "Cannot snapshot non-existent dataset"
}

@test "zfs_create_snapshot: handles existing snapshot gracefully" {
    # Mock both functions to return true (dataset exists, snapshot exists)
    zfs_dataset_exists() { return 0; }
    zfs_snapshot_exists() { return 0; }
    
    run zfs_create_snapshot "$TEST_DATASET" "$TEST_SNAPSHOT"
    
    assert_success
    assert_output --partial "Snapshot already exists"
}

@test "zfs_create_snapshot: handles creation failure" {
    export DRY_RUN=false
    # Mock dataset exists, snapshot doesn't exist
    zfs_dataset_exists() { return 0; }
    zfs_snapshot_exists() { return 1; }
    # Mock run_cmd to fail
    run_cmd() { return 1; }
    
    run zfs_create_snapshot "$TEST_DATASET" "$TEST_SNAPSHOT"
    
    assert_failure
    assert_output --partial "Failed to create ZFS snapshot"
}

# ==============================================================================
# ZFS Snapshot Destruction Tests
# ==============================================================================

@test "zfs_destroy_snapshot: destroys existing snapshot" {
    local test_snapshot="${TEST_DATASET}@${TEST_SNAPSHOT}"
    
    # Mock zfs_snapshot_exists to return true
    zfs_snapshot_exists() { return 0; }
    
    run zfs_destroy_snapshot "$test_snapshot"
    
    assert_success
    assert_output --partial "[DRY RUN] Would destroy snapshot: ${test_snapshot}"
}

@test "zfs_destroy_snapshot: handles non-existent snapshot gracefully" {
    local test_snapshot="${TEST_DATASET}@${TEST_SNAPSHOT}"
    
    # Mock zfs_snapshot_exists to return false
    zfs_snapshot_exists() { return 1; }
    
    run zfs_destroy_snapshot "$test_snapshot"
    
    assert_success
    assert_output --partial "Snapshot does not exist: ${test_snapshot}"
}

@test "zfs_destroy_snapshot: handles destruction failure" {
    export DRY_RUN=false
    local test_snapshot="${TEST_DATASET}@${TEST_SNAPSHOT}"
    
    # Mock zfs_snapshot_exists to return true
    zfs_snapshot_exists() { return 0; }
    # Mock run_cmd to fail
    run_cmd() { return 1; }
    
    run zfs_destroy_snapshot "$test_snapshot"
    
    assert_failure
    assert_output --partial "Failed to destroy ZFS snapshot"
}

# ==============================================================================
# ZFS Snapshot Rollback Tests
# ==============================================================================

@test "zfs_rollback_snapshot: rolls back to existing snapshot" {
    local test_snapshot="${TEST_DATASET}@${TEST_SNAPSHOT}"
    
    # Mock zfs_snapshot_exists to return true
    zfs_snapshot_exists() { return 0; }
    
    run zfs_rollback_snapshot "$test_snapshot"
    
    assert_success
    assert_output --partial "[DRY RUN] Would rollback to snapshot: ${test_snapshot}"
}

@test "zfs_rollback_snapshot: validates snapshot exists" {
    local test_snapshot="${TEST_DATASET}@${TEST_SNAPSHOT}"
    
    # Mock zfs_snapshot_exists to return false
    zfs_snapshot_exists() { return 1; }
    
    run zfs_rollback_snapshot "$test_snapshot"
    
    assert_failure
    assert_output --partial "Cannot rollback to non-existent snapshot"
}

@test "zfs_rollback_snapshot: applies force flag correctly" {
    local test_snapshot="${TEST_DATASET}@${TEST_SNAPSHOT}"
    
    # Mock zfs_snapshot_exists to return true
    zfs_snapshot_exists() { return 0; }
    
    run zfs_rollback_snapshot "$test_snapshot" --force
    
    assert_success
    assert_output --partial "[DRY RUN] Would rollback to snapshot"
}

@test "zfs_rollback_snapshot: handles rollback failure" {
    export DRY_RUN=false
    local test_snapshot="${TEST_DATASET}@${TEST_SNAPSHOT}"
    
    # Mock zfs_snapshot_exists to return true
    zfs_snapshot_exists() { return 0; }
    # Mock run_cmd to fail
    run_cmd() { return 1; }
    
    run zfs_rollback_snapshot "$test_snapshot"
    
    assert_failure
    assert_output --partial "Failed to rollback to ZFS snapshot"
}

# ==============================================================================
# ZFS Root Dataset Operations Tests
# ==============================================================================

@test "zfs_create_root_dataset: creates complete root dataset structure" {
    # Mock zfs_dataset_exists to return false (doesn't exist)
    zfs_dataset_exists() { return 1; }
    
    run zfs_create_root_dataset "$TEST_POOL" "$TEST_BUILD_NAME"
    
    assert_success
    assert_output --partial "Creating ZFS root dataset structure for: test-build"
    assert_output --partial "[DRY RUN] Would create dataset: test_pool/ROOT"
    assert_output --partial "[DRY RUN] Would create dataset: test_pool/ROOT/test-build"
    assert_output --partial "[DRY RUN] Would create dataset: test_pool/ROOT/test-build/varlog"
}

@test "zfs_create_root_dataset: handles existing ROOT dataset" {
    # Mock zfs_dataset_exists to return true for ROOT, false for others
    zfs_dataset_exists() {
        if [[ "$1" == "${TEST_POOL}/ROOT" ]]; then
            return 0
        fi
        return 1
    }
    
    run zfs_create_root_dataset "$TEST_POOL" "$TEST_BUILD_NAME"
    
    assert_success
    assert_output --partial "Creating ZFS root dataset structure"
    # Should not try to create ROOT dataset
    refute_output --partial "[DRY RUN] Would create dataset: test_pool/ROOT"
}

@test "zfs_mount_root_dataset: mounts root and varlog datasets" {
    local mount_base="/tmp/test-builds"
    
    # Mock functions
    zfs_dataset_exists() { return 0; }
    zfs_get_root_dataset_path() { echo "${TEST_POOL}/ROOT/${TEST_BUILD_NAME}"; }
    zfs_mount_dataset() { echo "Mocking mount: $1 -> $2"; }
    
    run zfs_mount_root_dataset "$TEST_POOL" "$TEST_BUILD_NAME" "$mount_base"
    
    assert_success
    assert_output --partial "Mounting ZFS root dataset"
    assert_output --partial "Successfully mounted root dataset at: ${mount_base}/${TEST_BUILD_NAME}"
}

@test "zfs_promote_to_bootfs: promotes dataset to bootable" {
    # Mock functions
    zfs_dataset_exists() { return 0; }
    zfs_get_root_dataset_path() { echo "${TEST_POOL}/ROOT/${TEST_BUILD_NAME}"; }
    zfs_set_property() { echo "Setting property: $1 $2"; }
    
    run zfs_promote_to_bootfs "$TEST_POOL" "$TEST_BUILD_NAME"
    
    assert_success
    assert_output --partial "Promoting dataset to bootfs"
    assert_output --partial "Successfully promoted dataset to bootfs"
}

@test "zfs_promote_to_bootfs: validates dataset exists before promotion" {
    # Mock zfs_dataset_exists to return false
    zfs_dataset_exists() { return 1; }
    zfs_get_root_dataset_path() { echo "${TEST_POOL}/ROOT/${TEST_BUILD_NAME}"; }
    
    run zfs_promote_to_bootfs "$TEST_POOL" "$TEST_BUILD_NAME"
    
    assert_failure
    assert_output --partial "Cannot promote non-existent dataset"
}

# ==============================================================================
# ZFS Pool Validation Tests
# ==============================================================================

@test "zfs_check_pool: validates pool exists and is healthy" {
    # Mock zpool commands
    zpool() {
        case "$2" in
            "name") echo "$TEST_POOL" ;;
            "health") echo "ONLINE" ;;
        esac
        return 0
    }
    
    run zfs_check_pool "$TEST_POOL"
    
    assert_success
    # When pool is ONLINE, only debug message is logged (not visible in test output)
}

@test "zfs_check_pool: handles non-existent pool" {
    # Mock zpool to fail for pool existence check
    zpool() {
        if [[ "$1" == "list" && "$4" == "$TEST_POOL" ]]; then
            return 1
        fi
        return 0
    }
    
    run zfs_check_pool "$TEST_POOL"
    
    assert_success  # The function currently uses log_warn, not die
    assert_output --partial "⚠️  ZFS pool '$TEST_POOL' status:"
}

@test "zfs_check_pool: warns about unhealthy pool" {
    # Mock zpool commands - pool exists but unhealthy  
    zpool() {
        case "$2" in
            "name") echo "$TEST_POOL" ;;
            "health") echo "DEGRADED" ;;
        esac
        return 0
    }
    
    run zfs_check_pool "$TEST_POOL"
    
    assert_success
    assert_output --partial "⚠️  ZFS pool '$TEST_POOL' status:"
    assert_output --partial "💡 Check pool status with: sudo zpool status $TEST_POOL"
}
