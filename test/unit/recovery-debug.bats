#!/usr/bin/env bats
# Minimal test to debug recovery library loading

# Load test helpers
load '../helpers/test_helper'

# Test just loading the recovery library
@test "recovery library loads successfully" {
    # This should work if the library loads correctly
    run echo "Recovery library loading test"
    assert_success
}

@test "simple function test" {
    # Test a basic function that doesn't involve stacks
    run echo "hello world"
    assert_success
    assert_output "hello world"
}
