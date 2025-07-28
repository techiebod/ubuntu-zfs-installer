#!/usr/bin/env bats
# Tests for lib/build-status.sh - Build status state management

# Load test helpers
load '../helpers/test_helper'

# Source the build-status library under test
source "${PROJECT_ROOT}/lib/build-status.sh"

# Setup/teardown
setup() {
    # Create test environment variables
    export TEST_BUILD_NAME="test-build"
    export TEST_STATUS_DIR="/tmp/test-status"
    export TEST_STATUS_FILE="${TEST_STATUS_DIR}/${TEST_BUILD_NAME}.status"
    export TEST_LOG_FILE="${TEST_STATUS_DIR}/${TEST_BUILD_NAME}.log"
    
    # Mock STATUS_DIR for testing
    export STATUS_DIR="$TEST_STATUS_DIR"
    
    # Mock dry run mode by default for safety
    export DRY_RUN=true
    
    # Create test status directory
    mkdir -p "$TEST_STATUS_DIR"
    
    # Clear any existing cleanup stack
    clear_cleanup_stack 2>/dev/null || true
}

teardown() {
    # Clean up test files
    rm -rf "$TEST_STATUS_DIR"
    
    # Reset environment
    unset TEST_BUILD_NAME TEST_STATUS_DIR TEST_STATUS_FILE TEST_LOG_FILE
    unset STATUS_DIR DRY_RUN
}

# ==============================================================================
# Build Status File Management Tests
# ==============================================================================

@test "build_get_status_file: returns correct status file path" {
    run build_get_status_file "$TEST_BUILD_NAME"
    
    assert_success
    assert_output "$TEST_STATUS_FILE"
}

@test "build_get_log_file: returns correct log file path" {
    run build_get_log_file "$TEST_BUILD_NAME"
    
    assert_success
    assert_output "$TEST_LOG_FILE"
}

@test "build_get_status_file: handles empty build name" {
    run build_get_status_file ""
    
    assert_success
    assert_output "${TEST_STATUS_DIR}/.status"
}

# ==============================================================================
# Build Status Setting Tests
# ==============================================================================

@test "build_set_status: creates status entry with timestamp" {
    export DRY_RUN=false
    
    run build_set_status "$TEST_BUILD_NAME" "$STATUS_STARTED"
    
    assert_success
    assert_output --partial "Setting build status: $TEST_BUILD_NAME -> $STATUS_STARTED"
    
    # Verify status file was created
    [[ -f "$TEST_STATUS_FILE" ]]
    
    # Verify status file contains the status
    grep -q "$STATUS_STARTED" "$TEST_STATUS_FILE"
}

@test "build_set_status: respects dry run mode" {
    run build_set_status "$TEST_BUILD_NAME" "$STATUS_STARTED"
    
    assert_success
    assert_output --partial "[DRY RUN] Would set status: $TEST_BUILD_NAME -> $STATUS_STARTED"
    
    # Verify status file was not created in dry run
    [[ ! -f "$TEST_STATUS_FILE" ]]
}

@test "build_set_status: validates status value" {
    run build_set_status "$TEST_BUILD_NAME" "invalid-status"
    
    assert_failure
    assert_output --partial "Invalid status: invalid-status"
}

@test "build_set_status: appends to existing status file" {
    export DRY_RUN=false
    
    # Set initial status
    build_set_status "$TEST_BUILD_NAME" "$STATUS_STARTED" >/dev/null
    
    # Set second status
    run build_set_status "$TEST_BUILD_NAME" "$STATUS_DATASETS_CREATED"
    
    assert_success
    
    # Verify both statuses are in file
    grep -q "$STATUS_STARTED" "$TEST_STATUS_FILE"
    grep -q "$STATUS_DATASETS_CREATED" "$TEST_STATUS_FILE"
}

@test "build_set_status: includes optional message" {
    export DRY_RUN=false
    local test_message="Custom status message"
    
    run build_set_status "$TEST_BUILD_NAME" "$STATUS_STARTED" "$test_message"
    
    assert_success
    assert_output --partial "Setting build status: $TEST_BUILD_NAME -> $STATUS_STARTED"
    
    # Verify message is in status file
    grep -q "$test_message" "$TEST_STATUS_FILE"
}

# ==============================================================================
# Build Status Retrieval Tests
# ==============================================================================

@test "build_get_status: returns current status from file" {
    export DRY_RUN=false
    
    # Create status file with multiple entries using correct pipe format
    echo "$(date -Iseconds)|$STATUS_STARTED|test message" > "$TEST_STATUS_FILE"
    echo "$(date -Iseconds)|$STATUS_DATASETS_CREATED|another message" >> "$TEST_STATUS_FILE"
    
    run build_get_status "$TEST_BUILD_NAME"
    
    assert_success
    assert_output "$STATUS_DATASETS_CREATED"
}

@test "build_get_status: returns empty for non-existent build" {
    run build_get_status "non-existent-build"
    
    assert_success
    assert_output ""
}

@test "build_get_status: returns empty for empty status file" {
    export DRY_RUN=false
    
    # Create empty status file
    touch "$TEST_STATUS_FILE"
    
    run build_get_status "$TEST_BUILD_NAME"
    
    assert_success
    assert_output ""
}

@test "build_get_status_timestamp: returns timestamp of current status" {
    export DRY_RUN=false
    local test_timestamp="2024-01-01T12:00:00+00:00"
    
    # Create status file with known timestamp using correct pipe format
    echo "$test_timestamp|$STATUS_STARTED|test message" > "$TEST_STATUS_FILE"
    
    run build_get_status_timestamp "$TEST_BUILD_NAME"
    
    assert_success
    assert_output "$test_timestamp"
}

@test "build_get_status_timestamp: returns empty for non-existent build" {
    run build_get_status_timestamp "non-existent-build"
    
    assert_success
    assert_output ""
}

# ==============================================================================
# Build Status Clearing Tests
# ==============================================================================

@test "build_clear_status: removes status and log files" {
    export DRY_RUN=false
    
    # Create test files
    echo "test status" > "$TEST_STATUS_FILE"
    echo "test log" > "$TEST_LOG_FILE"
    
    run build_clear_status "$TEST_BUILD_NAME"
    
    assert_success
    assert_output --partial "Clearing build status: $TEST_BUILD_NAME"
    
    # Verify files were removed
    [[ ! -f "$TEST_STATUS_FILE" ]]
    [[ ! -f "$TEST_LOG_FILE" ]]
}

@test "build_clear_status: respects dry run mode" {
    export DRY_RUN=false
    
    # Create test files
    echo "test status" > "$TEST_STATUS_FILE"
    echo "test log" > "$TEST_LOG_FILE"
    
    # Set dry run and clear
    export DRY_RUN=true
    run build_clear_status "$TEST_BUILD_NAME"
    
    assert_success
    assert_output --partial "Clearing build status: $TEST_BUILD_NAME"
    # In DRY_RUN mode, run_cmd should not execute the rm commands
    assert_output --partial "[DRY RUN] Would execute: rm -f"
    
    # Verify files still exist in dry run
    [[ -f "$TEST_STATUS_FILE" ]]
    [[ -f "$TEST_LOG_FILE" ]]
}

@test "build_clear_status: handles non-existent files gracefully" {
    export DRY_RUN=false
    
    run build_clear_status "$TEST_BUILD_NAME"
    
    assert_success
    assert_output --partial "Clearing build status: $TEST_BUILD_NAME"
}

@test "build_clear_status: with force flag removes additional artifacts" {
    export DRY_RUN=false
    
    # Create test files and additional artifacts
    echo "test status" > "$TEST_STATUS_FILE"
    echo "test log" > "$TEST_LOG_FILE"
    mkdir -p "${TEST_STATUS_DIR}/artifacts"
    echo "artifact" > "${TEST_STATUS_DIR}/artifacts/${TEST_BUILD_NAME}.tmp"
    
    run build_clear_status "$TEST_BUILD_NAME" --force
    
    assert_success
    assert_output --partial "Force clearing all artifacts for: $TEST_BUILD_NAME"
}

# ==============================================================================
# Build Stage Progression Tests
# ==============================================================================

@test "build_get_next_stage: returns correct next stage" {
    # Test progression through all stages
    run build_get_next_stage "$STATUS_STARTED"
    assert_success
    assert_output "$STATUS_DATASETS_CREATED"
    
    run build_get_next_stage "$STATUS_DATASETS_CREATED"
    assert_success
    assert_output "$STATUS_ROOT_MOUNTED"
    
    run build_get_next_stage "$STATUS_ROOT_MOUNTED"
    assert_success
    assert_output "$STATUS_OS_INSTALLED"
    
    run build_get_next_stage "$STATUS_OS_INSTALLED"
    assert_success
    assert_output "$STATUS_VARLOG_MOUNTED"
    
    run build_get_next_stage "$STATUS_VARLOG_MOUNTED"
    assert_success
    assert_output "$STATUS_CONTAINER_CREATED"
    
    run build_get_next_stage "$STATUS_CONTAINER_CREATED"
    assert_success
    assert_output "$STATUS_ANSIBLE_CONFIGURED"
    
    run build_get_next_stage "$STATUS_ANSIBLE_CONFIGURED"
    assert_success
    assert_output "$STATUS_COMPLETED"
}

@test "build_get_next_stage: returns empty for completed status" {
    run build_get_next_stage "$STATUS_COMPLETED"
    
    assert_success
    assert_output ""
}

@test "build_get_next_stage: returns empty for invalid status" {
    run build_get_next_stage "invalid-status"
    
    assert_success
    assert_output ""
}

@test "build_get_next_stage: handles invalid status" {
    run build_get_next_stage "invalid-status"
    
    assert_success
    assert_output ""
}

# ==============================================================================
# Build Stage Execution Logic Tests
# ==============================================================================

@test "build_should_run_stage: allows stage when no current status" {
    run build_should_run_stage "$STATUS_DATASETS_CREATED" "$TEST_BUILD_NAME"
    
    assert_success
}

@test "build_should_run_stage: allows next stage in progression" {
    export DRY_RUN=false
    
    # Set current status using correct pipe format
    echo "$(date -Iseconds)|$STATUS_STARTED|test message" > "$TEST_STATUS_FILE"
    
    run build_should_run_stage "$STATUS_DATASETS_CREATED" "$TEST_BUILD_NAME"
    
    assert_success
}

@test "build_should_run_stage: prevents skipping stages" {
    export DRY_RUN=false
    
    # Set current status using correct pipe format
    echo "$(date -Iseconds)|$STATUS_STARTED|test message" > "$TEST_STATUS_FILE"
    
    run build_should_run_stage "$STATUS_OS_INSTALLED" "$TEST_BUILD_NAME"
    
    assert_failure
}

@test "build_should_run_stage: prevents re-running completed stages" {
    export DRY_RUN=false
    
    # Set current status to completed stage using correct pipe format
    echo "$(date -Iseconds)|$STATUS_DATASETS_CREATED|test message" > "$TEST_STATUS_FILE"
    
    run build_should_run_stage "$STATUS_DATASETS_CREATED" "$TEST_BUILD_NAME"
    
    assert_failure
}

@test "build_should_run_stage: handles force restart properly" {
    export DRY_RUN=false
    
    # Set current status to a completed stage
    echo "$(date -Iseconds)|$STATUS_COMPLETED|build completed" > "$TEST_STATUS_FILE"
    
    # Force restart should allow any stage to run
    run build_should_run_stage "$STATUS_DATASETS_CREATED" "$TEST_BUILD_NAME" true
    
    assert_success
}

# ==============================================================================
# Build Listing and Information Tests
# ==============================================================================

@test "build_list_all_with_status: lists all builds with their status" {
    export DRY_RUN=false
    
    # Create multiple test builds
    echo "$(date -Iseconds)|$STATUS_STARTED|build started" > "${TEST_STATUS_DIR}/build1.status"
    echo "$(date -Iseconds)|$STATUS_COMPLETED|build completed" > "${TEST_STATUS_DIR}/build2.status"
    
    run build_list_all_with_status
    
    assert_success
    assert_output --partial "Build Status Summary:"
    assert_output --partial "build1"
    assert_output --partial "build2"
    assert_output --partial "$STATUS_STARTED"
    assert_output --partial "$STATUS_COMPLETED"
}

@test "build_list_all_with_status: handles empty status directory" {
    # Remove all status files
    rm -f "${TEST_STATUS_DIR}"/*.status 2>/dev/null || true
    
    run build_list_all_with_status
    
    assert_success
    assert_output --partial "No builds found"
}

@test "build_show_details: displays comprehensive build information" {
    export DRY_RUN=false
    
    # Create status file with multiple entries
    echo "$(date -Iseconds)|$STATUS_STARTED|Initial build start" > "$TEST_STATUS_FILE"
    echo "$(date -Iseconds)|$STATUS_DATASETS_CREATED|ZFS datasets created" >> "$TEST_STATUS_FILE"
    
    # Mock all ZFS functions that are checked
    zfs_get_root_dataset_path() { echo "rpool/ROOT/$1"; }
    zfs_dataset_exists() { return 0; }
    zfs_get_property() { echo "1.5G"; }
    
    run build_show_details "$TEST_BUILD_NAME"
    
    assert_success
    assert_output --partial "Build Details for: $TEST_BUILD_NAME"
    assert_output --partial "Current Status: $STATUS_DATASETS_CREATED"
    assert_output --partial "ZFS Dataset Information:"
}

@test "build_show_details: handles non-existent build" {
    run build_show_details "non-existent-build"
    
    assert_success
    assert_output --partial "Build Details for: non-existent-build"
}

# ==============================================================================
# Build History Tests
# ==============================================================================

@test "build_show_history: displays status progression" {
    export DRY_RUN=false
    
    # Create status file with progression using correct pipe format
    echo "$(date -Iseconds)|$STATUS_STARTED|Build initiated" > "$TEST_STATUS_FILE"
    echo "$(date -Iseconds)|$STATUS_DATASETS_CREATED|ZFS setup complete" >> "$TEST_STATUS_FILE"
    echo "$(date -Iseconds)|$STATUS_OS_INSTALLED|Base OS ready" >> "$TEST_STATUS_FILE"
    
    run build_show_history "$TEST_BUILD_NAME"
    
    assert_success
    assert_output --partial "Build History for: $TEST_BUILD_NAME"
    assert_output --partial "$STATUS_STARTED"
    assert_output --partial "$STATUS_DATASETS_CREATED"
    assert_output --partial "$STATUS_OS_INSTALLED"
}

@test "build_show_history: handles non-existent build" {
    run build_show_history "non-existent-build"
    
    assert_failure
    assert_output --partial "No build history found for: non-existent-build"
}

@test "build_show_history: with --tail option shows recent entries" {
    export DRY_RUN=false
    
    # Create status file with many entries using correct pipe format
    for i in {1..10}; do
        echo "2024-01-01T10:0${i}:00+00:00|status-${i}|Message ${i}" >> "$TEST_STATUS_FILE"
    done
    
    run build_show_history "$TEST_BUILD_NAME" --tail 3
    
    assert_success
    assert_output --partial "Last 3 entries"
    # Should show entries 8, 9, 10
    assert_output --partial "status-8"
    assert_output --partial "status-9"
    assert_output --partial "status-10"
    # Should not show early entries
    refute_output --partial "status-1"
}

# ==============================================================================
# Build Cleanup Tests
# ==============================================================================

@test "build_clean_all_artifacts: removes all build artifacts" {
    export DRY_RUN=false
    
    # Create various build artifacts
    echo "test status" > "${TEST_STATUS_DIR}/build1.status"
    echo "test log" > "${TEST_STATUS_DIR}/build1.log"
    echo "test status" > "${TEST_STATUS_DIR}/build2.status"
    mkdir -p "${TEST_STATUS_DIR}/temp"
    echo "temp file" > "${TEST_STATUS_DIR}/temp/build.tmp"
    
    run build_clean_all_artifacts
    
    assert_success
    assert_output --partial "Cleaning all build artifacts"
    
    # Verify artifacts were removed
    [[ ! -f "${TEST_STATUS_DIR}/build1.status" ]]
    [[ ! -f "${TEST_STATUS_DIR}/build1.log" ]]
    [[ ! -f "${TEST_STATUS_DIR}/build2.status" ]]
}

@test "build_clean_all_artifacts: respects dry run mode" {
    export DRY_RUN=false
    
    # Create test artifacts
    echo "test status" > "${TEST_STATUS_DIR}/build1.status"
    
    # Set dry run and clean
    export DRY_RUN=true
    run build_clean_all_artifacts
    
    assert_success
    assert_output --partial "[DRY RUN] Would clean all artifacts in: $TEST_STATUS_DIR"
    
    # Verify files still exist in dry run
    [[ -f "${TEST_STATUS_DIR}/build1.status" ]]
}

@test "build_clean_all_artifacts: with --force removes protected files" {
    export DRY_RUN=false
    
    # Create test artifacts including protected files
    echo "test status" > "${TEST_STATUS_DIR}/build1.status"
    echo "protected" > "${TEST_STATUS_DIR}/.protected"
    
    run build_clean_all_artifacts --force
    
    assert_success
    assert_output --partial "Force cleaning all artifacts (including protected files)"
}

# ==============================================================================
# Build Logging Tests
# ==============================================================================

@test "build_log_event: logs events to build log file" {
    export DRY_RUN=false
    local test_event="Test event message"
    
    run build_log_event "$TEST_BUILD_NAME" "$test_event"
    
    assert_success
    assert_output --partial "Logging event for $TEST_BUILD_NAME: $test_event"
    
    # Verify event was logged
    [[ -f "$TEST_LOG_FILE" ]]
    grep -q "$test_event" "$TEST_LOG_FILE"
}

@test "build_log_event: respects dry run mode" {
    local test_event="Test event message"
    
    run build_log_event "$TEST_BUILD_NAME" "$test_event"
    
    assert_success
    assert_output --partial "[DRY RUN] Would log event: $test_event"
    
    # Verify log file was not created
    [[ ! -f "$TEST_LOG_FILE" ]]
}

@test "build_log_event: includes timestamp in log entry" {
    export DRY_RUN=false
    local test_event="Test event with timestamp"
    
    build_log_event "$TEST_BUILD_NAME" "$test_event" >/dev/null
    
    # Verify timestamp format in log file
    grep -q "^[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\} [0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\}" "$TEST_LOG_FILE"
}

@test "build_set_logging_context: sets context for subsequent logs" {
    export DRY_RUN=false
    local test_context="dataset-creation"
    
    # Set the logging context
    build_set_logging_context "$TEST_BUILD_NAME" "$test_context"
    
    # Verify the context was set
    [[ "${BUILD_LOG_CONTEXT:-}" == "$test_context" ]]
    
    # Context should be available for next log entry
    build_log_event "$TEST_BUILD_NAME" "Test message" >/dev/null
    grep -q "$test_context" "$TEST_LOG_FILE"
}
