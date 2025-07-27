#!/usr/bin/env bats
#
# Unit tests for lib/ubuntu-api.sh
#

# Test setup
setup() {
    # Set up PROJECT_ROOT for tests
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    
    # Load the library under test
    source "$PROJECT_ROOT/lib/ubuntu-api.sh"
}

# ==============================================================================
# LIBRARY LOADING TESTS
# ==============================================================================

@test "ubuntu-api library loads without errors" {
    # Library should already be loaded by setup
    [[ "${__UBUNTU_API_LIB_LOADED:-}" == "true" ]]
}

@test "ubuntu-api library initializes global variables" {
    # Should have initialized empty dist variables
    [[ -v DIST_VERSION ]]
    [[ -v DIST_CODENAME ]]
}

# ==============================================================================
# NON-NETWORK UTILITY TESTS
# ==============================================================================

@test "resolve_dist_info handles non-ubuntu distributions" {
    # For non-ubuntu distributions, both version and codename must be provided
    run resolve_dist_info "debian" "12" "bookworm"
    [[ $status -eq 0 ]]
    
    # After running the function, check the global variables
    # Note: These are set in the function's environment, not the test's run environment
    # We need to call the function directly, not through run
    resolve_dist_info "debian" "12" "bookworm"
    [[ "$DIST_VERSION" == "12" ]]
    [[ "$DIST_CODENAME" == "bookworm" ]]
}

@test "resolve_dist_info fails for non-ubuntu with missing version" {
    run resolve_dist_info "debian" "" "bookworm"
    [[ $status -ne 0 ]]
    [[ "$output" =~ "both --version and --codename must be provided" ]]
}

@test "resolve_dist_info fails for non-ubuntu with missing codename" {
    run resolve_dist_info "debian" "12" ""
    [[ $status -ne 0 ]]
    [[ "$output" =~ "both --version and --codename must be provided" ]]
}

# ==============================================================================
# NETWORK-DEPENDENT TESTS (CONDITIONAL)
# ==============================================================================
# These tests require network access and external APIs to be available
# They will be skipped if network is unavailable or APIs are down

@test "get_default_ubuntu_codename returns a codename" {
    # Skip if no network or curl/jq unavailable
    if ! command -v curl &>/dev/null || ! command -v jq &>/dev/null; then
        skip "curl or jq not available for network tests"
    fi
    
    # Try to ping the API - skip if network is down
    if ! curl -s --connect-timeout 5 "https://api.launchpad.net/1.0/ubuntu/series" &>/dev/null; then
        skip "Ubuntu API not reachable - network may be down"
    fi
    
    run get_default_ubuntu_codename
    [[ $status -eq 0 ]]
    [[ -n "$output" ]]
    # Should return a valid Ubuntu codename (letters only)
    [[ "$output" =~ ^[a-z]+$ ]]
}

@test "_get_ubuntu_codename_for_version works for known versions" {
    # Skip if no network or dependencies
    if ! command -v curl &>/dev/null || ! command -v jq &>/dev/null; then
        skip "curl or jq not available for network tests"
    fi
    
    if ! curl -s --connect-timeout 5 "https://api.launchpad.net/1.0/ubuntu/series" &>/dev/null; then
        skip "Ubuntu API not reachable"
    fi
    
    # Test with a well-known stable version
    run _get_ubuntu_codename_for_version "22.04"
    [[ $status -eq 0 ]]
    [[ "$output" == "jammy" ]]
}

@test "_get_ubuntu_version_for_codename works for known codenames" {
    # Skip if no network or dependencies
    if ! command -v curl &>/dev/null || ! command -v jq &>/dev/null; then
        skip "curl or jq not available for network tests"
    fi
    
    if ! curl -s --connect-timeout 5 "https://api.launchpad.net/1.0/ubuntu/series" &>/dev/null; then
        skip "Ubuntu API not reachable"
    fi
    
    # Test with a well-known codename
    run _get_ubuntu_version_for_codename "jammy"
    [[ $status -eq 0 ]]
    [[ "$output" == "22.04" ]]
}

@test "_get_latest_ubuntu_version returns a version number" {
    # Skip if no network or dependencies
    if ! command -v curl &>/dev/null || ! command -v jq &>/dev/null; then
        skip "curl or jq not available for network tests"
    fi
    
    if ! curl -s --connect-timeout 5 "https://api.launchpad.net/1.0/ubuntu/series" &>/dev/null; then
        skip "Ubuntu API not reachable"
    fi
    
    run _get_latest_ubuntu_version
    [[ $status -eq 0 ]]
    [[ -n "$output" ]]
    # Should return a version number format like "24.04"
    [[ "$output" =~ ^[0-9]+\.[0-9]+$ ]]
}

# ==============================================================================
# INTEGRATION TESTS
# ==============================================================================

@test "resolve_dist_info handles ubuntu with version only" {
    # Skip if no network dependencies
    if ! command -v curl &>/dev/null || ! command -v jq &>/dev/null; then
        skip "curl or jq not available for network tests"
    fi
    
    if ! curl -s --connect-timeout 5 "https://api.launchpad.net/1.0/ubuntu/series" &>/dev/null; then
        skip "Ubuntu API not reachable"
    fi
    
    # Should resolve 22.04 to jammy
    run resolve_dist_info "ubuntu" "22.04" ""
    [[ $status -eq 0 ]]
    [[ "$DIST_VERSION" == "22.04" ]]
    [[ "$DIST_CODENAME" == "jammy" ]]
}

@test "resolve_dist_info handles ubuntu with codename only" {
    # Skip if no network dependencies
    if ! command -v curl &>/dev/null || ! command -v jq &>/dev/null; then
        skip "curl or jq not available for network tests"
    fi
    
    if ! curl -s --connect-timeout 5 "https://api.launchpad.net/1.0/ubuntu/series" &>/dev/null; then
        skip "Ubuntu API not reachable"
    fi
    
    # Should resolve jammy to 22.04
    run resolve_dist_info "ubuntu" "" "jammy"
    [[ $status -eq 0 ]]
    [[ "$DIST_VERSION" == "22.04" ]]
    [[ "$DIST_CODENAME" == "jammy" ]]
}

# ==============================================================================
# ERROR HANDLING TESTS
# ==============================================================================

@test "ubuntu-api functions handle missing dependencies gracefully" {
    # This test would need to mock the absence of curl/jq
    # For now, we just ensure the functions exist and can be called
    declare -F _get_ubuntu_codename_for_version >/dev/null
    declare -F _get_ubuntu_version_for_codename >/dev/null
    declare -F _get_latest_ubuntu_version >/dev/null
    declare -F resolve_dist_info >/dev/null
    declare -F get_default_ubuntu_codename >/dev/null
}
