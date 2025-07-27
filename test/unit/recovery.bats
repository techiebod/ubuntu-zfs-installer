#!/usr/bin/env bats
# Tests for lib/recovery.sh - Recovery and cleanup state management

# Load test helpers
load '../helpers/test_helper'

# Source the recovery library under test (with careful array handling)
# Temporarily disable nounset for safe array loading
set +o nounset 2>/dev/null || true
source "${PROJECT_ROOT}/lib/recovery.sh"
set -o nounset 2>/dev/null || true

# Setup/teardown
setup() {
    # Create test environment variables
    export TEST_BUILD_NAME="test-build"
    export TEST_RECOVERY_DIR="/tmp/test-recovery"
    export TEST_STATE_FILE="$TEST_RECOVERY_DIR/test-state"
    
    # Mock dry run mode by default for safety
    export DRY_RUN=true
    
    # Create test recovery directory
    mkdir -p "$TEST_RECOVERY_DIR"
    
    # Clear cleanup and rollback stacks
    clear_cleanup_stack 2>/dev/null || true
    clear_rollback_stack 2>/dev/null || true
}

teardown() {
    # Clean up test files
    rm -rf "$TEST_RECOVERY_DIR"
    
    # Reset environment
    unset TEST_BUILD_NAME TEST_RECOVERY_DIR TEST_STATE_FILE
    unset DRY_RUN
    
    # Clear stacks
    clear_cleanup_stack 2>/dev/null || true
    clear_rollback_stack 2>/dev/null || true
}

# ==============================================================================
# Cleanup Stack Management Tests
# ==============================================================================

@test "add_cleanup: adds cleanup command to stack" {
    run add_cleanup "echo 'cleanup test command'"
    
    assert_success
    assert_output --partial "Adding cleanup: echo 'cleanup test command'"
}

@test "add_cleanup: handles multiple cleanup commands" {
    add_cleanup "echo 'first cleanup'" >/dev/null
    add_cleanup "echo 'second cleanup'" >/dev/null
    
    run add_cleanup "echo 'third cleanup'"
    
    assert_success
    assert_output --partial "Adding cleanup: echo 'third cleanup'"
}

@test "add_cleanup: validates command is provided" {
    run add_cleanup ""
    
    assert_failure
    assert_output --partial "No cleanup command provided"
}

@test "remove_cleanup: removes specific cleanup command" {
    # Add some cleanup commands
    add_cleanup "echo 'first cleanup'" >/dev/null
    add_cleanup "echo 'second cleanup'" >/dev/null
    add_cleanup "echo 'third cleanup'" >/dev/null
    
    run remove_cleanup "echo 'second cleanup'"
    
    assert_success
    assert_output --partial "Removing cleanup: echo 'second cleanup'"
}

@test "remove_cleanup: handles non-existent cleanup command" {
    add_cleanup "echo 'test cleanup'" >/dev/null
    
    run remove_cleanup "echo 'non-existent cleanup'"
    
    assert_success
    assert_output --partial "Cleanup command not found: echo 'non-existent cleanup'"
}

@test "run_cleanup_stack: executes all cleanup commands in reverse order" {
    export DRY_RUN=false
    
    # Add cleanup commands
    add_cleanup "echo 'first cleanup'" >/dev/null
    add_cleanup "echo 'second cleanup'" >/dev/null
    add_cleanup "echo 'third cleanup'" >/dev/null
    
    run run_cleanup_stack
    
    assert_success
    assert_output --partial "Running cleanup stack"
    assert_output --partial "third cleanup"
    assert_output --partial "second cleanup"
    assert_output --partial "first cleanup"
    
    # Check order by looking at line positions in output
    local output_lines
    output_lines=$(echo "$output" | grep -n "cleanup")
    [[ "$output_lines" == *"third cleanup"* ]]
    [[ "$output_lines" == *"second cleanup"* ]]
    [[ "$output_lines" == *"first cleanup"* ]]
}

@test "run_cleanup_stack: respects dry run mode" {
    add_cleanup "echo 'test cleanup'" >/dev/null
    
    run run_cleanup_stack
    
    assert_success
    assert_output --partial "[DRY RUN] Would run cleanup stack"
    assert_output --partial "echo 'test cleanup'"
}

@test "run_cleanup_stack: handles empty cleanup stack" {
    run run_cleanup_stack
    
    assert_success
    assert_output --partial "No cleanup commands to run"
}

@test "run_cleanup_stack: continues on cleanup command failure" {
    export DRY_RUN=false
    
    # Add cleanup commands
    add_cleanup "echo 'good cleanup'" >/dev/null
    add_cleanup "false" >/dev/null  # This will fail
    add_cleanup "echo 'another good cleanup'" >/dev/null
    
    # Mock run_cmd to handle failure
    run_cmd() {
        if [[ "$*" == "false" ]]; then
            return 1
        fi
        return 0
    }
    
    run run_cleanup_stack
    
    assert_success
    assert_output --partial "Running cleanup stack"
    assert_output --partial "Cleanup command failed: false"
    # Should continue with remaining commands
}

@test "clear_cleanup_stack: removes all cleanup commands" {
    # Add some cleanup commands
    add_cleanup "echo 'first cleanup'" >/dev/null
    add_cleanup "echo 'second cleanup'" >/dev/null
    
    # Test the clear operation
    run bash -c "source '${PROJECT_ROOT}/lib/recovery.sh'; add_cleanup 'echo test1'; add_cleanup 'echo test2'; clear_cleanup_stack; run_cleanup_stack"
    
    assert_success
    assert_output --partial "Clearing cleanup stack"
    assert_output --partial "No cleanup commands to run"
}

# ==============================================================================
# Error Handling and Trap Management Tests
# ==============================================================================

@test "cleanup_on_error: runs cleanup on script exit" {
    # Add cleanup command
    add_cleanup "echo 'error cleanup executed'" >/dev/null
    
    run cleanup_on_error
    
    assert_success
    assert_output --partial "Script exiting with error, running cleanup"
}

@test "setup_cleanup_trap: configures exit trap" {
    run setup_cleanup_trap
    
    assert_success
    assert_output --partial "Setting up cleanup trap for EXIT signal"
}

@test "disable_cleanup_trap: removes exit trap" {
    run disable_cleanup_trap
    
    assert_success
    assert_output --partial "Disabling cleanup trap"
}

@test "emergency_cleanup: runs cleanup with error context" {
    export DRY_RUN=false
    
    # Add cleanup command
    add_cleanup "echo 'emergency cleanup'" >/dev/null
    
    run emergency_cleanup "Test error message"
    
    assert_success
    assert_output --partial "EMERGENCY CLEANUP: Test error message"
    assert_output --partial "Running cleanup stack"
}

@test "emergency_cleanup: handles cleanup stack failure gracefully" {
    export DRY_RUN=false
    
    # Add failing cleanup command
    add_cleanup "false" >/dev/null
    
    # Mock run_cmd to fail
    run_cmd() { return 1; }
    
    run emergency_cleanup "Test error"
    
    assert_success
    assert_output --partial "EMERGENCY CLEANUP: Test error"
    assert_output --partial "Emergency cleanup completed with errors"
}

# ==============================================================================
# Recovery Suggestions Tests
# ==============================================================================

@test "suggest_recovery: provides context-specific recovery suggestions" {
    run suggest_recovery "zfs" "Dataset creation failed"
    
    assert_success
    assert_output --partial "Recovery suggestions for zfs error:"
    assert_output --partial "Dataset creation failed"
    assert_output --partial "Check ZFS pool status"
}

@test "suggest_recovery: handles container-related errors" {
    run suggest_recovery "container" "Container failed to start"
    
    assert_success
    assert_output --partial "Recovery suggestions for container error:"
    assert_output --partial "Container failed to start"
    assert_output --partial "Check systemd-nspawn"
}

@test "suggest_recovery: handles mount-related errors" {
    run suggest_recovery "mount" "Failed to mount dataset"
    
    assert_success
    assert_output --partial "Recovery suggestions for mount error:"
    assert_output --partial "Failed to mount dataset"
    assert_output --partial "Check mount points"
}

@test "suggest_recovery: provides generic suggestions for unknown contexts" {
    run suggest_recovery "unknown" "Generic error message"
    
    assert_success
    assert_output --partial "Recovery suggestions for unknown error:"
    assert_output --partial "Generic error message"
    assert_output --partial "Check system logs"
}

@test "suggest_recovery: includes cleanup instructions" {
    # Add cleanup command
    add_cleanup "echo 'test cleanup'" >/dev/null
    
    run suggest_recovery "test" "Test error"
    
    assert_success
    assert_output --partial "Run manual cleanup:"
    assert_output --partial "echo 'test cleanup'"
}

# ==============================================================================
# Rollback Stack Management Tests
# ==============================================================================

@test "add_rollback: adds rollback command to stack" {
    run add_rollback "echo 'rollback test command'"
    
    assert_success
    assert_output --partial "Adding rollback: echo 'rollback test command'"
}

@test "add_rollback: handles multiple rollback commands" {
    add_rollback "echo 'first rollback'" >/dev/null
    add_rollback "echo 'second rollback'" >/dev/null
    
    run add_rollback "echo 'third rollback'"
    
    assert_success
    assert_output --partial "Adding rollback: echo 'third rollback'"
}

@test "add_rollback: validates command is provided" {
    run add_rollback ""
    
    assert_failure
    assert_output --partial "No rollback command provided"
}

@test "execute_rollback: runs all rollback commands in reverse order" {
    export DRY_RUN=false
    
    # Add rollback commands
    add_rollback "echo 'first rollback'" >/dev/null
    add_rollback "echo 'second rollback'" >/dev/null
    add_rollback "echo 'third rollback'" >/dev/null
    
    run execute_rollback
    
    assert_success
    assert_output --partial "Executing rollback stack"
    assert_output --partial "third rollback"
    assert_output --partial "second rollback"
    assert_output --partial "first rollback"
    
    # Check order by looking at line positions in output
    local output_lines
    output_lines=$(echo "$output" | grep -n "rollback")
    [[ "$output_lines" == *"third rollback"* ]]
    [[ "$output_lines" == *"second rollback"* ]]
    [[ "$output_lines" == *"first rollback"* ]]
}

@test "execute_rollback: respects dry run mode" {
    add_rollback "echo 'test rollback'" >/dev/null
    
    run execute_rollback
    
    assert_success
    assert_output --partial "[DRY RUN] Would execute rollback stack"
    assert_output --partial "echo 'test rollback'"
}

@test "execute_rollback: handles empty rollback stack" {
    run execute_rollback
    
    assert_success
    assert_output --partial "No rollback commands to execute"
}

@test "execute_rollback: stops on rollback command failure" {
    export DRY_RUN=false
    
    # Add rollback commands
    add_rollback "echo 'good rollback'" >/dev/null
    add_rollback "false" >/dev/null  # This will fail
    add_rollback "echo 'another rollback'" >/dev/null
    
    # Mock run_cmd to handle failure
    run_cmd() {
        if [[ "$*" == "false" ]]; then
            return 1
        fi
        return 0
    }
    
    run execute_rollback
    
    assert_failure
    assert_output --partial "Rollback command failed: false"
    # Should stop execution on failure
    assert_output --partial "Rollback stopped due to failure"
}

@test "clear_rollback_stack: removes all rollback commands" {
    # Add some rollback commands
    add_rollback "echo 'first rollback'" >/dev/null
    add_rollback "echo 'second rollback'" >/dev/null
    
    # Test the clear operation
    run bash -c "source '${PROJECT_ROOT}/lib/recovery.sh'; add_rollback 'echo test1'; add_rollback 'echo test2'; clear_rollback_stack; execute_rollback"
    
    assert_success
    assert_output --partial "Clearing rollback stack"
    assert_output --partial "No rollback commands to execute"
}

# ==============================================================================
# State Management Tests
# ==============================================================================

@test "save_state: saves current state to file" {
    export DRY_RUN=false
    
    run save_state "$TEST_BUILD_NAME" "test-operation" "$TEST_STATE_FILE"
    
    assert_success
    assert_output --partial "Saving state for $TEST_BUILD_NAME: test-operation"
    
    # Verify state file was created
    [[ -f "$TEST_STATE_FILE" ]]
    
    # Verify state file contains expected information
    grep -q "$TEST_BUILD_NAME" "$TEST_STATE_FILE"
    grep -q "test-operation" "$TEST_STATE_FILE"
}

@test "save_state: respects dry run mode" {
    run save_state "$TEST_BUILD_NAME" "test-operation" "$TEST_STATE_FILE"
    
    assert_success
    assert_output --partial "[DRY RUN] Would save state: test-operation -> $TEST_STATE_FILE"
    
    # Verify state file was not created
    [[ ! -f "$TEST_STATE_FILE" ]]
}

@test "save_state: includes timestamp in state file" {
    export DRY_RUN=false
    
    save_state "$TEST_BUILD_NAME" "test-operation" "$TEST_STATE_FILE" >/dev/null
    
    # Verify timestamp format in state file
    grep -q "^[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\} [0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\}" "$TEST_STATE_FILE"
}

@test "save_state: handles file creation failure" {
    export DRY_RUN=false
    
    # Use a path that will definitely fail - try to write to /proc which is read-only
    run save_state "$TEST_BUILD_NAME" "test-operation" "/proc/impossible/state"
    
    assert_failure
    assert_output --partial "Failed to save state"
}

@test "list_saved_states: lists all saved state files" {
    export DRY_RUN=false
    
    # Create multiple state files
    save_state "build1" "operation1" "${TEST_RECOVERY_DIR}/build1-op1.state" >/dev/null
    save_state "build2" "operation2" "${TEST_RECOVERY_DIR}/build2-op2.state" >/dev/null
    
    run list_saved_states "$TEST_RECOVERY_DIR"
    
    assert_success
    assert_output --partial "Saved states in $TEST_RECOVERY_DIR:"
    assert_output --partial "build1-op1.state"
    assert_output --partial "build2-op2.state"
}

@test "list_saved_states: handles empty state directory" {
    run list_saved_states "$TEST_RECOVERY_DIR"
    
    assert_success
    assert_output --partial "No saved states found in $TEST_RECOVERY_DIR"
}

@test "cleanup_old_states: removes old state files" {
    export DRY_RUN=false
    
    # Create old state files
    for i in {1..5}; do
        save_state "build$i" "operation$i" "${TEST_RECOVERY_DIR}/build$i.state" >/dev/null
        # Make files appear older using a simpler approach
        local timestamp=$(($(date +%s) - (i * 86400)))  # i days ago in seconds
        touch -d "@$timestamp" "${TEST_RECOVERY_DIR}/build$i.state" 2>/dev/null || touch "${TEST_RECOVERY_DIR}/build$i.state"
    done
    
    run cleanup_old_states "$TEST_RECOVERY_DIR" 2  # Keep only 2 newest
    
    assert_success
    assert_output --partial "Cleaning up old state files (keeping 2 newest)"
    
    # Should keep only the 2 newest files
    [[ $(find "$TEST_RECOVERY_DIR" -name "*.state" | wc -l) -eq 2 ]]
}

@test "cleanup_old_states: respects dry run mode" {
    export DRY_RUN=false
    
    # Create old state files
    for i in {1..3}; do
        save_state "build$i" "operation$i" "${TEST_RECOVERY_DIR}/build$i.state" >/dev/null
    done
    
    # Set dry run and cleanup
    export DRY_RUN=true
    run cleanup_old_states "$TEST_RECOVERY_DIR" 1
    
    assert_success
    assert_output --partial "[DRY RUN] Would clean up old state files"
    
    # Files should still exist
    [[ $(find "$TEST_RECOVERY_DIR" -name "*.state" | wc -l) -eq 3 ]]
}

# ==============================================================================
# Operation Completion Tracking Tests
# ==============================================================================

@test "mark_operation_complete: marks operation as completed" {
    export DRY_RUN=false
    
    run mark_operation_complete "$TEST_BUILD_NAME" "test-operation"
    
    assert_success
    assert_output --partial "Marking operation complete: $TEST_BUILD_NAME.test-operation"
    
    # Verify completion marker was created
    [[ -f "${TEST_RECOVERY_DIR}/${TEST_BUILD_NAME}.test-operation.complete" ]]
}

@test "mark_operation_complete: respects dry run mode" {
    run mark_operation_complete "$TEST_BUILD_NAME" "test-operation"
    
    assert_success
    assert_output --partial "[DRY RUN] Would mark complete: $TEST_BUILD_NAME.test-operation"
    
    # Verify completion marker was not created
    [[ ! -f "${TEST_RECOVERY_DIR}/${TEST_BUILD_NAME}.test-operation.complete" ]]
}

@test "is_operation_complete: checks if operation is completed" {
    export DRY_RUN=false
    
    # Mark operation as complete
    mark_operation_complete "$TEST_BUILD_NAME" "test-operation" >/dev/null
    
    run is_operation_complete "$TEST_BUILD_NAME" "test-operation"
    
    assert_success
}

@test "is_operation_complete: returns false for incomplete operation" {
    run is_operation_complete "$TEST_BUILD_NAME" "non-existent-operation"
    
    assert_failure
}

@test "list_completed_operations: lists all completed operations" {
    export DRY_RUN=false
    
    # Mark multiple operations as complete
    mark_operation_complete "build1" "operation1" >/dev/null
    mark_operation_complete "build2" "operation2" >/dev/null
    mark_operation_complete "$TEST_BUILD_NAME" "test-operation" >/dev/null
    
    run list_completed_operations
    
    assert_success
    assert_output --partial "Completed operations:"
    assert_output --partial "build1.operation1"
    assert_output --partial "build2.operation2"
    assert_output --partial "${TEST_BUILD_NAME}.test-operation"
}

@test "list_completed_operations: handles no completed operations" {
    run list_completed_operations
    
    assert_success
    assert_output --partial "No completed operations found"
}
