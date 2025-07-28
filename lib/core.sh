#!/bin/bash
#
# Core Library
#
# This is the minimal core initialization library that provides essential
# project structure, configuration, and global variables needed by all scripts.
# Individual scripts should load specific libraries they need after sourcing core.sh.

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
export DRY_RUN=false
export DEBUG=false
export LOG_WITH_TIMESTAMPS=true

# ==============================================================================
# UTILITY FUNCTIONS
# ==============================================================================

# Check if we're running in interactive mode (for logging behavior)
# Interactive mode = stdout is a terminal AND not in a build context
is_interactive_mode() {
    [[ -t 1 && -z "${BUILD_LOG_CONTEXT:-}" ]]
}

# ==============================================================================
# CORE INITIALIZATION COMPLETE
# ==============================================================================

# Core library provides essential project structure and configuration
# Individual scripts should load specific libraries they need after sourcing core.sh

# Export key variables for scripts
export PROJECT_ROOT
export CORE_LIB_DIR
export GLOBAL_CONFIG_FILE

# Export configuration defaults for shellcheck compatibility
export DEFAULT_DISTRIBUTION DEFAULT_POOL_NAME DEFAULT_ROOT_DATASET
export DEFAULT_MOUNT_BASE DEFAULT_ARCH DEFAULT_VARIANT DEFAULT_DOCKER_IMAGE
export STATUS_DIR LOG_LEVEL
