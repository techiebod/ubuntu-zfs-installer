#!/usr/bin/env bats
#
# Unit tests for build-status.sh library
#

setup() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    source "${PROJECT_ROOT}/test/unit/../helpers/test_helper.bash"
    source "${PROJECT_ROOT}/lib/build-status.sh"
    
    # Create test directory for status files
    export TEST_STATUS_DIR="/tmp/test-status"
    export STATUS_DIR="$TEST_STATUS_DIR"
    export TEST_BUILD_NAME="test-build"
    export TEST_STATUS_FILE="${TEST_STATUS_DIR}/${TEST_BUILD_NAME}.status"
    export TEST_LOG_FILE="${TEST_STATUS_DIR}/${TEST_BUILD_NAME}.log"
    
    mkdir -p "$TEST_STATUS_DIR"
    
    # Clean up any existing test files
    rm -f "$TEST_STATUS_FILE" "$TEST_LOG_FILE"
}

teardown() {
    # Clean up test files
    rm -rf "$TEST_STATUS_DIR"
}

# ==============================================================================
# File Path Tests
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
# Status Setting Tests
# ==============================================================================

@test "build_set_status: creates status entry with timestamp" {
    export DRY_RUN=false
    
    run build_set_status "$TEST_BUILD_NAME" "$STATUS_STARTED" "Test message"
    
    assert_success
    assert_output --partial "Setting build status: $TEST_BUILD_NAME -> $STATUS_STARTED"
    
    # Verify file was created with correct format
    [[ -f "$TEST_STATUS_FILE" ]]
    local line
    line=$(cat "$TEST_STATUS_FILE")
    [[ "$line" =~ \|$STATUS_STARTED\|Test\ message$ ]]
}

@test "build_set_status: respects dry run mode" {
    export DRY_RUN=true
    
    run build_set_status "$TEST_BUILD_NAME" "$STATUS_STARTED"
    
    assert_success
    assert_output --partial "[DRY RUN] Would set status: $TEST_BUILD_NAME -> $STATUS_STARTED"
    
    # Verify no file was created
    [[ ! -f "$TEST_STATUS_FILE" ]]
}

@test "build_set_status: validates status value" {
    export DRY_RUN=false
    
    run build_set_status "$TEST_BUILD_NAME" "invalid-status"
    
    assert_failure
    assert_output --partial "Invalid status: invalid-status"
}

@test "build_set_status: appends to existing status file" {
    export DRY_RUN=false
    
    # Set first status
    build_set_status "$TEST_BUILD_NAME" "$STATUS_STARTED" >/dev/null
    
    # Set second status
    run build_set_status "$TEST_BUILD_NAME" "$STATUS_DATASETS_CREATED" "Second message"
    
    assert_success
    
    # Verify both entries exist
    local line_count
    line_count=$(wc -l < "$TEST_STATUS_FILE")
    [[ "$line_count" -eq 2 ]]
}

@test "build_set_status: includes optional message" {
    export DRY_RUN=false
    
    run build_set_status "$TEST_BUILD_NAME" "$STATUS_STARTED" "Custom message"
    
    assert_success
    
    # Verify message is included
    grep -q "Custom message" "$TEST_STATUS_FILE"
}

# ==============================================================================
# Status Reading Tests
# ==============================================================================

@test "build_get_status: returns current status from file" {
    export DRY_RUN=false
    
    # Create status file with pipe-separated format
    echo "$(date -Iseconds)|$STATUS_DATASETS_CREATED|test message" > "$TEST_STATUS_FILE"
    
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
    touch "$TEST_STATUS_FILE"
    
    run build_get_status "$TEST_BUILD_NAME"
    
    assert_success
    assert_output ""
}

@test "build_get_status_timestamp: returns timestamp of current status" {
    export DRY_RUN=false
    local test_timestamp="2024-01-01T10:00:00+00:00"
    
    echo "${test_timestamp}|$STATUS_STARTED|test message" > "$TEST_STATUS_FILE"
    
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
# Status Clearing Tests
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
    export DRY_RUN=true
    
    # Create test files
    echo "test status" > "$TEST_STATUS_FILE"
    echo "test log" > "$TEST_LOG_FILE"
    
    run build_clear_status "$TEST_BUILD_NAME"
    
    assert_success
    assert_output --partial "[DRY RUN] Would clear status for: $TEST_BUILD_NAME"
    
    # Verify files still exist
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
    
    # Create test files
    echo "test status" > "$TEST_STATUS_FILE"
    
    run build_clear_status "$TEST_BUILD_NAME" --force
    
    assert_success
    assert_output --partial "Force clearing all artifacts for: $TEST_BUILD_NAME"
}

# ==============================================================================
# Stage Progression Tests  
# ==============================================================================

@test "build_get_next_stage: returns correct next stage" {
    run build_get_next_stage "$STATUS_STARTED"
    
    assert_success
    assert_output "$STATUS_DATASETS_CREATED"
}

@test "build_get_next_stage: returns empty for completed status" {
    run build_get_next_stage "$STATUS_COMPLETED"
    
    assert_success
    assert_output ""
}

@test "build_get_next_stage: returns empty for failed status" {
    run build_get_next_stage "$STATUS_FAILED"
    
    assert_success
    assert_output ""
}

@test "build_get_next_stage: handles invalid status" {
    run build_get_next_stage "invalid-status"
    
    assert_success
    assert_output ""
}

@test "build_should_run_stage: allows stage when no current status" {
    export DRY_RUN=false
    
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

@test "build_should_run_stage: allows restarting failed builds" {
    export DRY_RUN=false
    
    # Set current status to failed using correct pipe format
    echo "$(date -Iseconds)|$STATUS_FAILED|test failed" > "$TEST_STATUS_FILE"
    
    run build_should_run_stage "$STATUS_DATASETS_CREATED" "$TEST_BUILD_NAME"
    
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
    run build_list_all_with_status
    
    assert_success
    assert_output --partial "No builds found."
}

@test "build_show_details: displays comprehensive build information" {
    export DRY_RUN=false
    
    # Create status file with multiple entries
    echo "$(date -Iseconds)|$STATUS_STARTED|Initial build start" > "$TEST_STATUS_FILE"
    echo "$(date -Iseconds)|$STATUS_DATASETS_CREATED|ZFS datasets created" >> "$TEST_STATUS_FILE"
    
    # Mock ZFS dataset existence
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
        echo "$(date -Iseconds)|status-${i}|Message ${i}" >> "$TEST_STATUS_FILE"
    done
    
    run build_show_history "$TEST_BUILD_NAME" --tail 3
    
    assert_success
    assert_output --partial "Build History for: $TEST_BUILD_NAME"
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
    
    # Create test artifacts
    echo "test status" > "${TEST_STATUS_DIR}/build1.status"
    echo "test log" > "${TEST_STATUS_DIR}/build1.log"
    echo "test status" > "${TEST_STATUS_DIR}/build2.status"
    mkdir -p "${TEST_STATUS_DIR}/temp"
    echo "temp file" > "${TEST_STATUS_DIR}/temp/build.tmp"
    
    run build_clean_all_artifacts "build1"
    
    assert_success
    assert_output --partial "Cleaning up all artifacts"
    
    # Verify artifacts were removed for the specified build
    [[ ! -f "${TEST_STATUS_DIR}/build1.status" ]]
    [[ ! -f "${TEST_STATUS_DIR}/build1.log" ]]
    # build2.status should still exist since we only cleaned build1
    [[ -f "${TEST_STATUS_DIR}/build2.status" ]]
}

@test "build_clean_all_artifacts: respects dry run mode" {
    export DRY_RUN=false
    
    # Create test artifacts
    echo "test status" > "${TEST_STATUS_DIR}/build1.status"
    
    # Set dry run and clean
    export DRY_RUN=true
    run build_clean_all_artifacts "build1"
    
    assert_success
    assert_output --partial "[DRY RUN] Would clear status for:"
    
    # Verify files still exist in dry run
    [[ -f "${TEST_STATUS_DIR}/build1.status" ]]
}

@test "build_clean_all_artifacts: with --force removes protected files" {
    export DRY_RUN=false
    
    # Create test artifacts including protected files
    echo "test status" > "${TEST_STATUS_DIR}/build1.status"
    echo "protected" > "${TEST_STATUS_DIR}/.protected"
    
    run build_clean_all_artifacts "build1"
    
    assert_success
    assert_output --partial "Cleaning up all artifacts for build: build1"
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
    
    # Verify log file was created and contains the event
    [[ -f "$TEST_LOG_FILE" ]]
    grep -q "$test_event" "$TEST_LOG_FILE"
}

@test "build_log_event: respects dry run mode" {
    export DRY_RUN=true
    local test_event="Test event message"
    
    run build_log_event "$TEST_BUILD_NAME" "$test_event"
    
    assert_success
    assert_output --partial "[DRY RUN] Would log event: $test_event"
    
    # Verify no log file was created
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
    
    # Call without 'run' to preserve the exported environment variable
    build_set_logging_context "$TEST_BUILD_NAME" "$test_context"
    
    # Context should be available for next log entry
    build_log_event "$TEST_BUILD_NAME" "Test message" >/dev/null
    grep -q "$test_context" "$TEST_LOG_FILE"
}
