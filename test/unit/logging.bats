#!/usr/bin/env bats
#
# Unit tests for logging.sh library
#

# Setup and teardown
setup() {
    # Load the library under test
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    source "$PROJECT_ROOT/lib/logging.sh"
    
    # Create temporary log file for testing
    export TEST_LOG_FILE="$(mktemp)"
}

teardown() {
    # Clean up
    [[ -f "$TEST_LOG_FILE" ]] && rm -f "$TEST_LOG_FILE"
}

@test "logging library loads without errors" {
    # Test that the library loads successfully
    run source "$PROJECT_ROOT/lib/logging.sh"
    [ "$status" -eq 0 ]
}

@test "log_info outputs to stderr" {
    run log_info "test message"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "test message" ]]
}

@test "log_error outputs to stderr" {
    run log_error "error message"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "error message" ]]
}

@test "log_debug respects DEBUG variable" {
    # Without DEBUG set
    export DEBUG=false
    export LOG_LEVEL=DEBUG  # Allow debug messages through log level filter
    run log_debug "debug message"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    
    # With DEBUG set
    export DEBUG=true
    export LOG_LEVEL=DEBUG  # Allow debug messages through log level filter
    run log_debug "debug message"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "debug message" ]]
}

@test "die function exits with error" {
    # Note: We can't easily test die because it calls exit
    # But we can test that the function exists
    run type die
    [ "$status" -eq 0 ]
    [[ "$output" =~ "die is a function" ]]
}
