#!/usr/bin/env bats
#
# Unit tests for lib/core.sh
#

# Test setup
setup() {
    # Set up PROJECT_ROOT for tests
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    
    # Set up test environment variables
    export DRY_RUN=false
    export DEBUG=false
    export LOG_WITH_TIMESTAMPS=true
}

# ==============================================================================
# ENVIRONMENT SETUP TESTS
# ==============================================================================

@test "core library sets required global variables" {
    # Load just enough to test the structure
    source "$PROJECT_ROOT/lib/core.sh"
    
    # Check that essential paths are set
    [[ -n "$PROJECT_ROOT" ]]
    [[ -n "$CORE_LIB_DIR" ]]
    [[ -n "$GLOBAL_CONFIG_FILE" ]]
    
    # Check paths are absolute
    [[ "$PROJECT_ROOT" =~ ^/ ]]
    [[ "$CORE_LIB_DIR" =~ ^/ ]]
    [[ "$GLOBAL_CONFIG_FILE" =~ ^/ ]]
}

@test "core library loads constants successfully" {
    source "$PROJECT_ROOT/lib/core.sh"
    
    # Should have loaded constants library
    [[ "${__CONSTANTS_LIB_LOADED:-}" == "true" ]]
    
    # Should have basic constants available
    [[ -n "${VALID_INSTALL_PROFILES:-}" ]]
}

@test "core library provides essential structure" {
    source "$PROJECT_ROOT/lib/core.sh"
    
    # Should provide core variables without loading all libraries
    [[ -n "${PROJECT_ROOT:-}" ]]
    [[ -n "${CORE_LIB_DIR:-}" ]]
    [[ -n "${GLOBAL_CONFIG_FILE:-}" ]]
    
    # Should have constants loaded (minimal dependency)
    [[ "${__CONSTANTS_LIB_LOADED:-}" == "true" ]]
}

@test "core library sets default configuration values" {
    source "$PROJECT_ROOT/lib/core.sh"
    
    # Check that default configuration constants are set and readonly
    [[ -n "$DEFAULT_DISTRIBUTION" ]]
    [[ -n "$DEFAULT_POOL_NAME" ]]
    [[ -n "$DEFAULT_ROOT_DATASET" ]]
    [[ -n "$DEFAULT_MOUNT_BASE" ]]
    [[ -n "$DEFAULT_ARCH" ]]
    [[ -n "$STATUS_DIR" ]]
    [[ -n "$LOG_LEVEL" ]]
    
    # These should be reasonable defaults
    [[ "$DEFAULT_DISTRIBUTION" == "ubuntu" ]]
    [[ "$DEFAULT_POOL_NAME" == "zroot" ]]
    [[ "$DEFAULT_ARCH" == "amd64" ]]
}

@test "core library initializes global state variables" {
    source "$PROJECT_ROOT/lib/core.sh"
    
    # Check that global state variables are properly initialized
    [[ "$DRY_RUN" == "false" ]]
    [[ "$DEBUG" == "false" ]]
    [[ "$LOG_WITH_TIMESTAMPS" == "true" ]]
}

@test "core library prevents multiple loading" {
    # Load once
    source "$PROJECT_ROOT/lib/core.sh"
    
    # Verify it's marked as loaded
    [[ "${__CORE_LIB_LOADED:-}" == "true" ]]
    
    # Loading again should be safe (no-op)
    source "$PROJECT_ROOT/lib/core.sh"
    [[ "${__CORE_LIB_LOADED:-}" == "true" ]]
}

# ==============================================================================
# HELPER FUNCTION TESTS
# ==============================================================================

@test "core library uses modular design" {
    source "$PROJECT_ROOT/lib/core.sh"
    
    # Core should not automatically load all libraries
    [[ "${__LOGGING_LIB_LOADED:-}" != "true" ]]
    [[ "${__VALIDATION_LIB_LOADED:-}" != "true" ]]
    
    # But should provide the foundation for loading them
    [[ -d "$CORE_LIB_DIR" ]]
    [[ -f "$CORE_LIB_DIR/logging.sh" ]]
    [[ -f "$CORE_LIB_DIR/validation.sh" ]]
}

@test "core library exports essential variables" {
    source "$PROJECT_ROOT/lib/core.sh"
    
    # Key variables should be exported for use by scripts
    [[ -n "${PROJECT_ROOT:-}" ]]
    [[ -n "${CORE_LIB_DIR:-}" ]]
    [[ -n "${GLOBAL_CONFIG_FILE:-}" ]]
    
    # Configuration defaults should be exported
    [[ -n "${DEFAULT_DISTRIBUTION:-}" ]]
    [[ -n "${DEFAULT_POOL_NAME:-}" ]]
    [[ -n "${STATUS_DIR:-}" ]]
}

# ==============================================================================
# PATH AND FILE STRUCTURE TESTS
# ==============================================================================

@test "core library calculates project paths correctly" {
    source "$PROJECT_ROOT/lib/core.sh"
    
    # PROJECT_ROOT should be parent of lib directory
    [[ "$(basename "$CORE_LIB_DIR")" == "lib" ]]
    [[ "$PROJECT_ROOT" == "$(dirname "$CORE_LIB_DIR")" ]]
    
    # Global config file should be in config/ subdirectory
    [[ "$GLOBAL_CONFIG_FILE" == "$PROJECT_ROOT/config/global.conf" ]]
}

@test "core library finds expected project structure" {
    source "$PROJECT_ROOT/lib/core.sh"
    
    # Basic project structure should exist
    [[ -d "$PROJECT_ROOT/lib" ]]
    [[ -d "$PROJECT_ROOT/scripts" ]]
    [[ -d "$PROJECT_ROOT/config" ]]
    
    # Essential library files should exist
    [[ -f "$CORE_LIB_DIR/constants.sh" ]]
    [[ -f "$CORE_LIB_DIR/logging.sh" ]]
    [[ -f "$CORE_LIB_DIR/validation.sh" ]]
}

# ==============================================================================
# CONFIGURATION LOADING TESTS
# ==============================================================================

@test "core library handles missing global config gracefully" {
    # Temporarily rename config file if it exists
    local config_backup=""
    if [[ -f "../../config/global.conf" ]]; then
        config_backup="../../config/global.conf.bak.$$"
        mv "../../config/global.conf" "$config_backup"
    fi
    
    # Load core library - should work with fallback defaults
    run bash -c "source $PROJECT_ROOT/lib/core.sh 2>/dev/null; echo \$DEFAULT_DISTRIBUTION"
    [[ $status -eq 0 ]]
    [[ "$output" == *"ubuntu"* ]]
    
    # Restore config file if it was backed up
    if [[ -n "$config_backup" && -f "$config_backup" ]]; then
        mv "$config_backup" "../../config/global.conf"
    fi
}

@test "core library strict mode is properly set" {
    # Test that core library sets bash strict mode
    run bash -c "source $PROJECT_ROOT/lib/core.sh; set -o | grep -E '(errexit|nounset|pipefail)'"
    [[ $status -eq 0 ]]
    [[ "$output" =~ "errexit".*"on" ]]
    [[ "$output" =~ "nounset".*"on" ]]
    [[ "$output" =~ "pipefail".*"on" ]]
}
