#!/usr/bin/env bats
#
# Unit tests for validation.sh library
#

setup() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    source "$PROJECT_ROOT/lib/logging.sh"
    source "$PROJECT_ROOT/lib/constants.sh"
    source "$PROJECT_ROOT/lib/validation.sh"
}

@test "validation library loads without errors" {
    run source "$PROJECT_ROOT/lib/validation.sh"
    [ "$status" -eq 0 ]
}

@test "validate_build_name accepts valid names" {
    run validate_build_name "ubuntu-noble"
    [ "$status" -eq 0 ]
    
    run validate_build_name "test-build-123"
    [ "$status" -eq 0 ]
    
    run validate_build_name "simple"
    [ "$status" -eq 0 ]
}

@test "validate_build_name rejects invalid names" {
    run validate_build_name ""
    [ "$status" -ne 0 ]
    
    run validate_build_name "with spaces"
    [ "$status" -ne 0 ]
    
    run validate_build_name "with/slash"
    [ "$status" -ne 0 ]
    
    run validate_build_name "with@symbol"
    [ "$status" -ne 0 ]
}

@test "validate_hostname accepts valid hostnames" {
    run validate_hostname "server"
    [ "$status" -eq 0 ]
    
    run validate_hostname "web-server"
    [ "$status" -eq 0 ]
    
    run validate_hostname "host123"
    [ "$status" -eq 0 ]
}

@test "validate_hostname rejects invalid hostnames" {
    run validate_hostname ""
    [ "$status" -ne 0 ]
    
    run validate_hostname "with spaces"
    [ "$status" -ne 0 ]
    
    run validate_hostname "UPPERCASE"
    [ "$status" -ne 0 ]
}

@test "validate_install_profile accepts valid profiles" {
    run validate_install_profile "$INSTALL_PROFILE_MINIMAL"
    [ "$status" -eq 0 ]
    
    run validate_install_profile "$INSTALL_PROFILE_STANDARD"
    [ "$status" -eq 0 ]
    
    run validate_install_profile "$INSTALL_PROFILE_FULL"
    [ "$status" -eq 0 ]
}

@test "validate_install_profile rejects invalid profiles" {
    run validate_install_profile "invalid"
    [ "$status" -ne 0 ]
    
    run validate_install_profile ""
    [ "$status" -ne 0 ]
}
