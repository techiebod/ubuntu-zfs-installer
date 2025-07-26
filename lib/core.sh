#!/bin/bash
#
# Core Library
#
# This is the minimal core initialization library that sets up the environment
# and sources all other modular libraries. This provides a clean, modular architecture.

# --- Prevent multiple sourcing ---
if [[ "${__CORE_LIB_LOADED:-}" == "true" ]]; then
    return 0
fi
readonly __CORE_LIB_LOADED="true"

# --- Script Setup ---
# Enforce strict error handling
set -o errexit
set -o nounset
set -o pipefail

# --- Determine Project Structure ---
declare CORE_LIB_DIR
CORE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CORE_LIB_DIR

declare PROJECT_ROOT
PROJECT_ROOT="$(dirname "$CORE_LIB_DIR")"
readonly PROJECT_ROOT

readonly GLOBAL_CONFIG_FILE="$PROJECT_ROOT/config/global.conf"

# ==============================================================================
# CONSTANTS AND CONFIGURATION LOADING
# ==============================================================================

# Load constants first (required by other libraries)
if [[ -f "$CORE_LIB_DIR/constants.sh" ]]; then
    source "$CORE_LIB_DIR/constants.sh"
else
    echo "FATAL: Constants library not found at $CORE_LIB_DIR/constants.sh" >&2
    exit 1
fi

# Load global configuration if it exists
if [[ -f "$GLOBAL_CONFIG_FILE" ]]; then
    # shellcheck source=../config/global.conf
    source "$GLOBAL_CONFIG_FILE"
else
    # Fallback to hardcoded defaults if config file is missing
    echo "Warning: Global config file not found at $GLOBAL_CONFIG_FILE, using fallback defaults" >&2
    DEFAULT_DISTRIBUTION="ubuntu"
    DEFAULT_POOL_NAME="zroot"
    DEFAULT_ROOT_DATASET="ROOT"
    DEFAULT_MOUNT_BASE="/var/tmp/zfs-builds"
    DEFAULT_ARCH="amd64"
    DEFAULT_VARIANT="apt"
    DEFAULT_DOCKER_IMAGE="ubuntu:latest"
    STATUS_DIR="/var/tmp/zfs-builds"
    LOG_LEVEL="INFO"
fi

# Make configuration values readonly
readonly DEFAULT_DISTRIBUTION
readonly DEFAULT_POOL_NAME
readonly DEFAULT_ROOT_DATASET
readonly DEFAULT_MOUNT_BASE
readonly DEFAULT_ARCH
readonly DEFAULT_VARIANT
readonly DEFAULT_DOCKER_IMAGE
readonly STATUS_DIR
readonly LOG_LEVEL

# --- Global State Variables ---
# These are intended to be set by the calling script via argument parsing
export VERBOSE=false
export DRY_RUN=false
export DEBUG=false
export LOG_WITH_TIMESTAMPS=true

# ==============================================================================
# MODULAR LIBRARY LOADING
# ==============================================================================

# Load core libraries in dependency order
# Note: Each library handles its own dependency loading

# 1. Logging (no dependencies)
if [[ -f "$CORE_LIB_DIR/logging.sh" ]]; then
    source "$CORE_LIB_DIR/logging.sh"
else
    echo "FATAL: Logging library not found at $CORE_LIB_DIR/logging.sh" >&2
    exit 1
fi

# 2. Dependencies (depends on logging)
if [[ -f "$CORE_LIB_DIR/dependencies.sh" ]]; then
    source "$CORE_LIB_DIR/dependencies.sh"
else
    echo "FATAL: Dependencies library not found at $CORE_LIB_DIR/dependencies.sh" >&2
    exit 1
fi

# 3. Validation (depends on logging)
if [[ -f "$CORE_LIB_DIR/validation.sh" ]]; then
    source "$CORE_LIB_DIR/validation.sh"
else
    echo "FATAL: Validation library not found at $CORE_LIB_DIR/validation.sh" >&2
    exit 1
fi

# 4. Execution (depends on logging)
if [[ -f "$CORE_LIB_DIR/execution.sh" ]]; then
    source "$CORE_LIB_DIR/execution.sh"
else
    echo "FATAL: Execution library not found at $CORE_LIB_DIR/execution.sh" >&2
    exit 1
fi

# 5. Recovery (depends on logging)
if [[ -f "$CORE_LIB_DIR/recovery.sh" ]]; then
    source "$CORE_LIB_DIR/recovery.sh"
else
    echo "FATAL: Recovery library not found at $CORE_LIB_DIR/recovery.sh" >&2
    exit 1
fi

# 6. Ubuntu API (depends on logging)
if [[ -f "$CORE_LIB_DIR/ubuntu-api.sh" ]]; then
    source "$CORE_LIB_DIR/ubuntu-api.sh"
else
    echo "FATAL: Ubuntu API library not found at $CORE_LIB_DIR/ubuntu-api.sh" >&2
    exit 1
fi

# 7. ZFS operations (existing library)
if [[ -f "$CORE_LIB_DIR/zfs.sh" ]]; then
    source "$CORE_LIB_DIR/zfs.sh"
else
    echo "FATAL: ZFS library not found at $CORE_LIB_DIR/zfs.sh" >&2
    exit 1
fi

# 8. Containers (existing library)
if [[ -f "$CORE_LIB_DIR/containers.sh" ]]; then
    source "$CORE_LIB_DIR/containers.sh"
else
    echo "FATAL: Containers library not found at $CORE_LIB_DIR/containers.sh" >&2
    exit 1
fi

# 9. Build Status (existing library)
if [[ -f "$CORE_LIB_DIR/build-status.sh" ]]; then
    source "$CORE_LIB_DIR/build-status.sh"
else
    echo "FATAL: Build status library not found at $CORE_LIB_DIR/build-status.sh" >&2
    exit 1
fi

# ==============================================================================
# INITIALIZATION AND SETUP
# ==============================================================================

# Initialize logging context
log_debug "Core library initialized successfully"
log_debug "Project root: $PROJECT_ROOT"
log_debug "Libraries loaded: logging, dependencies, validation, execution, recovery, ubuntu-api, zfs, containers, build-status"

# Set up cleanup trap by default (scripts can override this)
setup_cleanup_trap

# Initialize completed operations tracking
declare -gAx COMPLETED_OPERATIONS=()

# ==============================================================================
# BACKWARD COMPATIBILITY HELPERS
# ==============================================================================

# Helper function for scripts using the modular library system
# This provides a convenient initialization interface
init_common_environment() {
    log_debug "Initializing environment"
    
    # Validate global configuration
    validate_global_config
    
    log_debug "Environment initialized"
}

# --- Finalization ---
log_debug "Core library loading completed successfully"

# Export key variables for scripts
export PROJECT_ROOT
export CORE_LIB_DIR
export GLOBAL_CONFIG_FILE

# Export configuration defaults for shellcheck compatibility
export DEFAULT_DISTRIBUTION DEFAULT_POOL_NAME DEFAULT_ROOT_DATASET
export DEFAULT_MOUNT_BASE DEFAULT_ARCH DEFAULT_VARIANT DEFAULT_DOCKER_IMAGE
export STATUS_DIR LOG_LEVEL
