#!/usr/bin/env bats
#
# Unit tests for lib/execution.sh
#

# Test setup
setup() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    source "$PROJECT_ROOT/lib/execution.sh"
    
    # Set up test environment
    export VERBOSE=false
    export DRY_RUN=false
    export DEBUG=false
}

# ==============================================================================
# LIBRARY LOADING TESTS
# ==============================================================================

@test "execution library loads without errors" {
    # Library should already be loaded by setup
    [[ "${__EXECUTION_LIB_LOADED:-}" == "true" ]]
}

@test "execution library has required functions" {
    # Check that key functions are available
    declare -F run_cmd >/dev/null
    declare -F run_quiet >/dev/null
    declare -F run_capture >/dev/null
    declare -F parse_common_args >/dev/null
    declare -F execute_with_timeout >/dev/null
}

# ==============================================================================
# DRY RUN MODE TESTS
# ==============================================================================

@test "run_cmd respects DRY_RUN mode" {
    export DRY_RUN=true
    
    # Should not actually execute the command
    run run_cmd "false"
    [[ $status -eq 0 ]]  # Should succeed because it's dry run
    [[ "$output" =~ "DRY-RUN" ]]
}

@test "run_cmd executes commands when DRY_RUN is false" {
    export DRY_RUN=false
    
    # Should actually execute the command
    run run_cmd "true"
    [[ $status -eq 0 ]]
    
    # Should fail with false command
    run run_cmd "false"
    [[ $status -ne 0 ]]
}

# ==============================================================================
# COMMAND EXECUTION TESTS
# ==============================================================================

@test "run_cmd handles successful commands" {
    run run_cmd "echo" "test output"
    [[ $status -eq 0 ]]
}

@test "run_cmd handles failing commands" {
    run run_cmd "false"
    [[ $status -ne 0 ]]
}

@test "run_quiet suppresses output" {
    run run_quiet "echo" "this should be suppressed"
    [[ $status -eq 0 ]]
    [[ -z "$output" ]]
}

@test "run_capture returns command output" {
    run run_capture "echo" "captured output"
    [[ $status -eq 0 ]]
    [[ "$output" == "captured output" ]]
}

# ==============================================================================
# ARGUMENT PARSING TESTS
# ==============================================================================

@test "parse_common_args handles verbose flag" {
    # Test verbose short form
    export VERBOSE=false
    local remaining_args=()
    parse_common_args remaining_args "-v"
    [[ "$VERBOSE" == "true" ]]
    
    # Reset and test verbose long form
    export VERBOSE=false
    remaining_args=()
    parse_common_args remaining_args "--verbose"
    [[ "$VERBOSE" == "true" ]]
}

@test "parse_common_args handles dry-run flag" {
    # Test dry-run short form
    export DRY_RUN=false
    local remaining_args=()
    parse_common_args remaining_args "-n"
    [[ "$DRY_RUN" == "true" ]]
    
    # Reset and test dry-run long form
    export DRY_RUN=false
    remaining_args=()
    parse_common_args remaining_args "--dry-run"
    [[ "$DRY_RUN" == "true" ]]
}

@test "parse_common_args handles debug flag" {
    # Test debug short form
    export DEBUG=false
    local remaining_args=()
    parse_common_args remaining_args "-d"
    [[ "$DEBUG" == "true" ]]
    
    # Reset and test debug long form
    export DEBUG=false
    remaining_args=()
    parse_common_args remaining_args "--debug"
    [[ "$DEBUG" == "true" ]]
}

@test "parse_common_args handles multiple flags" {
    export VERBOSE=false
    export DRY_RUN=false
    export DEBUG=false
    
    local remaining_args=()
    parse_common_args remaining_args "-v" "-n" "-d"
    
    [[ "$VERBOSE" == "true" ]]
    [[ "$DRY_RUN" == "true" ]]
    [[ "$DEBUG" == "true" ]]
}

@test "parse_common_args handles unknown flags gracefully" {
    # Should not crash on unknown flags
    local remaining_args=()
    parse_common_args remaining_args "--unknown-flag"
    
    # Should succeed and put unknown flag in remaining args
    [[ ${#remaining_args[@]} -eq 1 ]]
    [[ "${remaining_args[0]}" == "--unknown-flag" ]]
}

# ==============================================================================
# HELPER FUNCTION TESTS
# ==============================================================================

@test "show_common_options_help produces output" {
    run show_common_options_help
    [[ $status -eq 0 ]]
    [[ -n "$output" ]]
    [[ "$output" =~ "verbose" ]]
    [[ "$output" =~ "dry-run" ]]
    [[ "$output" =~ "debug" ]]
}

@test "add_common_flags function exists" {
    # Function should exist and be callable
    declare -F add_common_flags >/dev/null
}

# ==============================================================================
# TIMEOUT EXECUTION TESTS
# ==============================================================================

@test "execute_with_timeout handles quick commands" {
    run execute_with_timeout 5 "echo" "quick command"
    [[ $status -eq 0 ]]
    [[ "$output" == "quick command" ]]
}

@test "execute_with_timeout handles timeout properly" {
    # Test with a command that would take longer than timeout
    # Use a very short timeout for testing
    run execute_with_timeout 1 "sleep" "10"
    [[ $status -ne 0 ]]  # Should fail due to timeout
}

# ==============================================================================
# SCRIPT EXECUTION TESTS
# ==============================================================================

@test "invoke_script function exists and is callable" {
    declare -F invoke_script >/dev/null
}

@test "execute_script function exists and is callable" {
    declare -F execute_script >/dev/null
}

# ==============================================================================
# BACKGROUND EXECUTION TESTS
# ==============================================================================

@test "execute_background function exists" {
    declare -F execute_background >/dev/null
}

@test "wait_for_background function exists" {
    declare -F wait_for_background >/dev/null
}

# Note: Background execution tests are skipped because they're complex
# and would require careful process management in the test environment

# ==============================================================================
# INTEGRATION TESTS  
# ==============================================================================

@test "execution library integrates with other libraries" {
    # Should be able to use execution functions after loading
    declare -F run_cmd >/dev/null
    declare -F run_quiet >/dev/null
    declare -F run_capture >/dev/null
    
    # Should be able to execute simple commands
    run run_cmd "true"
    [[ $status -eq 0 ]]
}
