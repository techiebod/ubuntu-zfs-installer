#!/usr/bin/env bash
#
# Test helpers for ubuntu-zfs-installer test suite
#

# --- Project root detection ---
if [[ -z "$PROJECT_ROOT" ]]; then
    # Get project root from test directory
    export PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

# --- Load only essential libraries for testing ---
# Don't load core.sh which enables nounset and could cause issues with empty arrays
# Instead, load libraries individually as needed

# Load logging first (required by most libraries)
source "${PROJECT_ROOT}/lib/logging.sh"

# Load constants 
source "${PROJECT_ROOT}/lib/constants.sh"

# Load execution for run_cmd function
source "${PROJECT_ROOT}/lib/execution.sh"

# Load validation
source "${PROJECT_ROOT}/lib/validation.sh"

# Load dependencies
source "${PROJECT_ROOT}/lib/dependencies.sh"

# NOTE: Recovery library is loaded individually in tests that need it
# to avoid nounset issues with empty arrays during mass loading

# --- Test assertion helpers ---

# Assert that command succeeded
assert_success() {
    if [[ "$status" -ne 0 ]]; then
        echo "Expected success but got exit code: $status"
        echo "Output: $output"
        return 1
    fi
}

# Assert that command failed
assert_failure() {
    if [[ "$status" -eq 0 ]]; then
        echo "Expected failure but command succeeded"
        echo "Output: $output"
        return 1
    fi
}

# Assert output contains expected content (handles timestamped logs)
assert_output() {
    local flag=""
    local expected=""
    
    if [[ $# -eq 2 && "$1" == "--partial" ]]; then
        flag="--partial"
        expected="$2"
    elif [[ $# -eq 1 ]]; then
        expected="$1"
    else
        echo "Usage: assert_output [--partial] <expected>"
        return 1
    fi
    
    if [[ "$flag" == "--partial" ]]; then
        # For partial matches, handle various log formats
        local cleaned_output="$output"
        
        # Remove timestamps: YYYY-MM-DD HH:MM:SS 
        cleaned_output=$(echo "$cleaned_output" | sed 's/^[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\} [0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\} //')
        
        # Remove just time stamps: HH:MM:SS
        cleaned_output=$(echo "$cleaned_output" | sed 's/^[0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\} //')
        
        # Remove log level prefixes but keep the message
        cleaned_output=$(echo "$cleaned_output" | sed 's/^\[INFO\] //' | sed 's/^\[WARN\] //' | sed 's/^\[ERROR\] //' | sed 's/^\[DEBUG\] //')
        
        # Check both original and cleaned output
        if [[ "$output" == *"$expected"* ]] || [[ "$cleaned_output" == *"$expected"* ]]; then
            return 0
        else
            echo "Expected output to contain: $expected"
            echo "Actual output: $output"
            echo "Cleaned output: $cleaned_output"
            return 1
        fi
    else
        # For exact matches, try both original and cleaned
        local cleaned_output="$output"
        cleaned_output=$(echo "$cleaned_output" | sed 's/^[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\} [0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\} //')
        cleaned_output=$(echo "$cleaned_output" | sed 's/^[0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\} //')
        
        if [[ "$output" == "$expected" ]] || [[ "$cleaned_output" == "$expected" ]]; then
            return 0
        else
            echo "Expected output: $expected"
            echo "Actual output: $output"
            echo "Cleaned output: $cleaned_output"
            return 1
        fi
    fi
}

# Assert output matches a regex pattern (for timestamped logs)
assert_output_regex() {
    if [[ $# -ne 1 ]]; then
        echo "Usage: assert_output_regex <regex_pattern>"
        return 1
    fi
    
    local pattern="$1"
    if [[ ! "$output" =~ $pattern ]]; then
        echo "Expected output to match regex: $pattern"
        echo "Actual output: $output"
        return 1
    fi
}

# Assert output does NOT contain specific text
refute_output() {
    local unwanted="$1"
    if [[ "$2" == "--partial" ]]; then
        unwanted="$3"
        if [[ "$output" == *"$unwanted"* ]]; then
            echo "Expected output to NOT contain: $unwanted"
            echo "Actual output: $output"
            return 1
        fi
    else
        if [[ "$output" == "$unwanted" ]]; then
            echo "Expected output to NOT be: $unwanted"
            echo "But output was: $output"
            return 1
        fi
    fi
}

# --- Mock helpers ---

# Mock function to check if ZFS dataset exists
zfs_dataset_exists() {
    local dataset="$1"
    
    # Return true for datasets we want to "exist" in tests
    case "$dataset" in
        "test_pool/ROOT"|"test_pool/ROOT/test-build"|"test_pool/ROOT/test-build/varlog")
            return 0
            ;;
        *)
            # Check if this is a test that wants the dataset to exist
            if [[ "${MOCK_DATASET_EXISTS:-false}" == "true" ]]; then
                return 0
            fi
            return 1
            ;;
    esac
}

# Mock function to check if ZFS snapshot exists  
zfs_snapshot_exists() {
    local snapshot="$1"
    
    if [[ "${MOCK_SNAPSHOT_EXISTS:-false}" == "true" ]]; then
        return 0
    fi
    return 1
}

# Mock zpool command
zpool() {
    case "$1" in
        "status")
            if [[ "${MOCK_POOL_HEALTHY:-false}" == "true" ]]; then
                echo "  pool: $2"
                echo " state: ONLINE"
                return 0
            else
                echo "  pool: $2"
                echo " state: DEGRADED"
                return 1
            fi
            ;;
        *)
            echo "Mocking zpool command: $*"
            return 0
            ;;
    esac
}

# Mock container status checks
container_is_running() {
    local container="$1"
    [[ "${MOCK_CONTAINER_RUNNING:-false}" == "true" ]]
}

# Mock machinectl command
machinectl() {
    case "$1" in
        "list")
            echo "[DRY-RUN] machinectl list"
            ;;
        "show")
            if [[ "${MOCK_CONTAINER_RUNNING:-false}" == "true" ]]; then
                echo "State=running"
            else
                echo "State=stopped"
            fi
            ;;
        *)
            echo "Mocking machinectl: $*"
            ;;
    esac
}

# Reset all function mocks
reset_mocks() {
    # List of functions that might be mocked
    local mockable_functions=(
        "zfs_dataset_exists"
        "zfs_snapshot_exists" 
        "zfs_get_property"
        "zfs_get_root_dataset_path"
        "zfs_get_varlog_dataset_path"
        "container_is_running"
        "container_validate_dataset"
        "machinectl"
        "zpool"
        "run_cmd"
    )
    
    for func in "${mockable_functions[@]}"; do
        if declare -f "$func" >/dev/null 2>&1; then
            unset -f "$func" 2>/dev/null || true
        fi
    done
    
    # Reset mock state variables
    unset MOCK_DATASET_EXISTS MOCK_SNAPSHOT_EXISTS MOCK_POOL_HEALTHY MOCK_CONTAINER_RUNNING
}

# --- Test environment helpers ---

# Setup common test environment
setup_test_env() {
    # Set safe defaults for testing
    export DRY_RUN=true
    export DEBUG=true  # Enable debug logging for better test visibility
    
    # Reset any existing state
    reset_mocks
    
    # Clear cleanup/rollback stacks if they exist
    clear_cleanup_stack 2>/dev/null || true
    clear_rollback_stack 2>/dev/null || true
}

# Cleanup test environment
cleanup_test_env() {
    # Reset mocks
    reset_mocks
    
    # Clear any test-specific environment variables
    local test_vars=(
        "TEST_POOL"
        "TEST_DATASET" 
        "TEST_BUILD_NAME"
        "TEST_CONTAINER_NAME"
        "TEST_MOUNT_POINT"
        "TEST_HOSTNAME"
        "TEST_SNAPSHOT"
        "TEST_STATUS_DIR"
        "TEST_STATUS_FILE"
        "TEST_LOG_FILE"
        "TEST_RECOVERY_DIR"
        "TEST_STATE_FILE"
    )
    
    for var in "${test_vars[@]}"; do
        unset "$var" 2>/dev/null || true
    done
    
    # Clear stacks
    clear_cleanup_stack 2>/dev/null || true
    clear_rollback_stack 2>/dev/null || true
}

# --- Utility functions ---

# Create temporary directory for tests
create_temp_dir() {
    local prefix="${1:-test}"
    mktemp -d "/tmp/${prefix}-XXXXXX"
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Skip test if command not available
skip_if_no_command() {
    local cmd="$1"
    local reason="${2:-Command $cmd not available}"
    
    if ! command_exists "$cmd"; then
        skip "$reason"
    fi
}

# Skip test if not running as root
skip_if_not_root() {
    local reason="${1:-Test requires root privileges}"
    
    if [[ "$EUID" -ne 0 ]]; then
        skip "$reason"
    fi
}

# Skip test if in CI environment
skip_if_ci() {
    local reason="${1:-Test not suitable for CI environment}"
    
    if [[ "${CI:-}" == "true" || "${GITHUB_ACTIONS:-}" == "true" ]]; then
        skip "$reason"
    fi
}
