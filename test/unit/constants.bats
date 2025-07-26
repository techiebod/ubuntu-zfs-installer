#!/usr/bin/env bats
#
# Unit tests for constants.sh library
#

setup() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    source "$PROJECT_ROOT/lib/constants.sh"
}

@test "constants library loads without errors" {
    run source "$PROJECT_ROOT/lib/constants.sh"
    [ "$status" -eq 0 ]
}

@test "install profiles are defined" {
    [ -n "$INSTALL_PROFILE_MINIMAL" ]
    [ -n "$INSTALL_PROFILE_STANDARD" ]
    [ -n "$INSTALL_PROFILE_FULL" ]
}

@test "valid install profiles array is populated" {
    [ ${#VALID_INSTALL_PROFILES[@]} -eq 3 ]
    [[ "${VALID_INSTALL_PROFILES[*]}" =~ "$INSTALL_PROFILE_MINIMAL" ]]
    [[ "${VALID_INSTALL_PROFILES[*]}" =~ "$INSTALL_PROFILE_STANDARD" ]]
    [[ "${VALID_INSTALL_PROFILES[*]}" =~ "$INSTALL_PROFILE_FULL" ]]
}

@test "profile seeds are defined" {
    [ -n "${PROFILE_SEEDS[$INSTALL_PROFILE_MINIMAL]}" ]
    [ -n "${PROFILE_SEEDS[$INSTALL_PROFILE_STANDARD]}" ]
    [ -n "${PROFILE_SEEDS[$INSTALL_PROFILE_FULL]}" ]
}

@test "architecture constants are defined" {
    [ -n "$ARCH_AMD64" ]
    [ -n "$ARCH_ARM64" ]
    [ -n "$ARCH_I386" ]
}

@test "timeout values are positive integers" {
    [[ "$DEFAULT_CONTAINER_TIMEOUT" =~ ^[0-9]+$ ]]
    [[ "$DEFAULT_NETWORK_TIMEOUT" =~ ^[0-9]+$ ]]
    [[ "$DEFAULT_ZFS_OPERATION_TIMEOUT" =~ ^[0-9]+$ ]]
    
    [ "$DEFAULT_CONTAINER_TIMEOUT" -gt 0 ]
    [ "$DEFAULT_NETWORK_TIMEOUT" -gt 0 ]
    [ "$DEFAULT_ZFS_OPERATION_TIMEOUT" -gt 0 ]
}
