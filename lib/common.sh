#!/bin/bash
#
# Common library for ZFS build scripts
#
# This library provides standardized functions for logging, command execution,
# error handling, and argument parsing. It is designed to be sourced by all
# other shell scripts in this project to ensure consistent behavior.
#
# To use, add this line at the top of your script:
# source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# --- Prevent multiple sourcing ---
if [[ "${__COMMON_LIB_LOADED:-}" == "true" ]]; then
    return 0
fi
readonly __COMMON_LIB_LOADED="true"

# --- Script Setup ---
# Enforce strict error handling
set -o errexit
set -o nounset
set -o pipefail

# --- Load Global Configuration ---
# Determine the project root directory (parent of lib/)
readonly COMMON_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(dirname "$COMMON_LIB_DIR")"
readonly GLOBAL_CONFIG_FILE="$PROJECT_ROOT/config/global.conf"

# Load global configuration if it exists
if [[ -f "$GLOBAL_CONFIG_FILE" ]]; then
    # shellcheck source=../config/global.conf
    source "$GLOBAL_CONFIG_FILE"
else
    # Fallback to hardcoded defaults if config file is missing
    echo "Warning: Global config file not found at $GLOBAL_CONFIG_FILE, using fallback defaults" >&2
    DEFAULT_DISTRIBUTION="ubuntu"
    DEFAULT_POOL_NAME="zroot"
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
readonly DEFAULT_MOUNT_BASE
readonly DEFAULT_ARCH
readonly DEFAULT_VARIANT
readonly DEFAULT_DOCKER_IMAGE
readonly STATUS_DIR
readonly LOG_LEVEL

# --- Global State Variables ---
# These are intended to be set by the calling script via argument parsing
VERBOSE=false
DRY_RUN=false
DEBUG=false
LOG_WITH_TIMESTAMPS=true

# ==============================================================================
# LOGGING FUNCTIONS
# ==============================================================================

# Log a message with a specified level (e.g., INFO, ERROR, DEBUG)
# Usage: _log "INFO" "This is an info message"
_log() {
    local level="$1"
    shift
    local prefix=""
    if [[ "${LOG_WITH_TIMESTAMPS:-true}" == "true" ]]; then
        prefix="$(date +'%Y-%m-%d %H:%M:%S') "
    fi
    # Prepend timestamp (if enabled) and level to the message, output to stderr
    echo "${prefix}[$level] $*" >&2
}

# --- Public Logging Functions ---
log_info() { _log "INFO" "$@"; }
log_error() { _log "ERROR" "$@"; }
log_warn() { _log "WARN" "$@"; }
log_debug() {
    if [[ "${DEBUG:-false}" == true ]]; then
        _log "DEBUG" "$@"
    fi
}

# Log an error and exit with a status of 1
# Usage: die "Something went terribly wrong"
die() {
    log_error "$@"
    exit 1
}

# ==============================================================================
# COMMAND EXECUTION
# ==============================================================================

# Run a command, respecting VERBOSE and DRY_RUN modes.
# If VERBOSE is true, output is streamed. Otherwise, it's captured.
# On failure, it logs the command, status code, and output before exiting.
# Usage: run_cmd "ls" "-l" "/tmp"
run_cmd() {
    local cmd_str="$*"
    log_debug "Executing command: $cmd_str"

    if [[ "${DRY_RUN:-false}" == true ]]; then
        log_info "[DRY-RUN] $cmd_str"
        return 0
    fi

    # Prepare for execution
    local output_file
    output_file=$(mktemp)
    local status=0

    if [[ "${VERBOSE:-false}" == true ]]; then
        # In verbose mode, stream output directly to stderr
        log_info "[EXEC] $cmd_str"
        "$@" > >(tee "$output_file") 2>&1 || status=$?
    else
        # In normal mode, capture output
        "$@" >"$output_file" 2>&1 || status=$?
    fi

    if [[ $status -ne 0 ]]; then
        log_error "Command failed with status $status: $cmd_str"
        log_error "Output:"
        # Minimal indent for readability
        sed 's/^/  /' "$output_file" >&2
        rm -f "$output_file"
        die "Aborting due to command failure."
    fi

    rm -f "$output_file"
    return 0
}

# ==============================================================================
# PREREQUISITE & VALIDATION CHECKS
# ==============================================================================

# Check if a required command is available in the system's PATH
# Usage: require_command "docker" "Docker is required to build images."
require_command() {
    local cmd="$1"
    local msg="${2:-Command '$cmd' is not installed or not in PATH.}"
    if ! command -v "$cmd" &>/dev/null; then
        die "$msg"
    fi
}

# Check if the specified ZFS pool exists
# Usage: check_zfs_pool "zroot"
check_zfs_pool() {
    local pool_name="${1:-$DEFAULT_POOL_NAME}"
    require_command "zpool"
    log_debug "Checking for ZFS pool '$pool_name'..."
    if ! zpool list -H -o name "$pool_name" &>/dev/null; then
        local available_pools
        available_pools=$(zpool list -H -o name | sed 's/^/    /' | tr '\n' ' ')
        die "ZFS pool '$pool_name' not found. Available pools are:${available_pools:- None}"
    fi
}

# Check if Docker is installed and the daemon is responsive
# Usage: check_docker
check_docker() {
    require_command "docker"
    log_debug "Checking Docker daemon status..."
    if ! docker info &>/dev/null; then
        die "Docker daemon is not running or not accessible. Please start Docker."
    fi
}

# ==============================================================================
# DISTRIBUTION & VERSIONING
# ==============================================================================

# --- Public Variables ---
# These will be populated by resolve_dist_info
DIST_VERSION=""
DIST_CODENAME=""

# --- Internal Functions ---

# Function to get codename for a given Ubuntu version.
# Returns codename string or empty string if not found.
_get_ubuntu_codename_for_version() {
    local version="$1"
    local codename
    codename=$(curl -s "https://api.launchpad.net/1.0/ubuntu/series" 2>/dev/null | \
               jq -r ".entries[] | select(.version == \"$version\") | .name" 2>/dev/null)

    if [[ -n "$codename" && "$codename" != "null" ]]; then
        echo "$codename"
    fi
}

# Function to get version for a given Ubuntu codename.
# Returns version string or empty string if not found.
_get_ubuntu_version_for_codename() {
    local codename_in="$1"
    local version
    version=$(curl -s "https://api.launchpad.net/1.0/ubuntu/series" 2>/dev/null | \
               jq -r ".entries[] | select(.name == \"$codename_in\") | .version" 2>/dev/null)

    if [[ -n "$version" && "$version" != "null" ]]; then
        echo "$version"
    fi
}

# Function to get the latest Ubuntu version number.
# Tries several methods to find the most recent release.
_get_latest_ubuntu_version() {
    local version=""

    # Method 1: Ubuntu Cloud Images (most up-to-date for releases)
    version=$(curl -s "https://cloud-images.ubuntu.com/releases/" 2>/dev/null | \
              grep -o 'href="[0-9][0-9]\.[0-9][0-9]/' | \
              grep -o '[0-9][0-9]\.[0-9][0-9]' | \
              sort -V | tail -1)

    if [[ -n "$version" ]]; then
        echo "$version"
        return 0
    fi

    # Method 2: Launchpad API fallback (current stable release)
    version=$(curl -s "https://api.launchpad.net/1.0/ubuntu/series" 2>/dev/null | \
              jq -r '.entries[] | select(.status == "Current Stable Release") | .version' 2>/dev/null)

    if [[ -n "$version" && "$version" != "null" ]]; then
        echo "$version"
        return 0
    fi

    # Method 3: Latest supported version from Launchpad
    version=$(curl -s "https://api.launchpad.net/1.0/ubuntu/series" 2>/dev/null | \
              jq -r '.entries[] | select(.status == "Supported") | .version' 2>/dev/null | \
              sort -V | tail -1)

    if [[ -n "$version" && "$version" != "null" ]]; then
        echo "$version"
        return 0
    fi
}

# --- Public Functions ---

# Resolve distribution version and codename from user input.
# Populates global DIST_VERSION and DIST_CODENAME.
# Usage: resolve_dist_info "ubuntu" "24.04" ""
#        resolve_dist_info "ubuntu" "" "noble"
#        resolve_dist_info "debian" "12" "bookworm"
resolve_dist_info() {
    local dist="$1"
    local version_in="$2"
    local codename_in="$3"

    log_debug "Resolving dist info for: dist='$dist', version='$version_in', codename='$codename_in'"

    if [[ "$dist" != "ubuntu" ]]; then
        # For non-ubuntu distributions, we can't do lookups yet.
        # Require both version and codename.
        if [[ -z "$version_in" || -z "$codename_in" ]]; then
            die "For distribution '$dist', both --version and --codename must be provided."
        fi
        DIST_VERSION="$version_in"
        DIST_CODENAME="$codename_in"
        log_info "Using custom distribution: $dist $DIST_VERSION ($DIST_CODENAME)"
        return 0
    fi

    # It's Ubuntu, let's resolve dynamically.
    require_command "curl" "curl is required to resolve Ubuntu versions."
    require_command "jq" "jq is required to resolve Ubuntu versions."

    if [[ -z "$version_in" && -z "$codename_in" ]]; then
        # Neither provided, get the latest version and its codename
        log_info "No version or codename specified, attempting to find latest Ubuntu release..."
        DIST_VERSION=$(_get_latest_ubuntu_version)
        if [[ -z "$DIST_VERSION" ]]; then
            die "Could not determine the latest Ubuntu version."
        fi
        DIST_CODENAME=$(_get_ubuntu_codename_for_version "$DIST_VERSION")
        if [[ -z "$DIST_CODENAME" ]]; then
            die "Could not determine codename for latest Ubuntu version '$DIST_VERSION'."
        fi

    elif [[ -n "$version_in" && -z "$codename_in" ]]; then
        # Version provided, find codename
        DIST_VERSION="$version_in"
        DIST_CODENAME=$(_get_ubuntu_codename_for_version "$DIST_VERSION")
        if [[ -z "$DIST_CODENAME" ]]; then
            die "Could not find a matching codename for Ubuntu version '$DIST_VERSION'."
        fi

    elif [[ -z "$version_in" && -n "$codename_in" ]]; then
        # Codename provided, find version
        DIST_CODENAME="$codename_in"
        DIST_VERSION=$(_get_ubuntu_version_for_codename "$DIST_CODENAME")
        if [[ -z "$DIST_VERSION" ]]; then
            die "Could not find a matching version for Ubuntu codename '$DIST_CODENAME'."
        fi

    elif [[ -n "$version_in" && -n "$codename_in" ]]; then
        # Both provided, validate they match
        local validation_codename
        validation_codename=$(_get_ubuntu_codename_for_version "$version_in")
        if [[ "$validation_codename" != "$codename_in" ]]; then
            die "Mismatch for Ubuntu: Version '$version_in' does not correspond to codename '$codename_in'. Found '$validation_codename'."
        fi
        DIST_VERSION="$version_in"
        DIST_CODENAME="$codename_in"
    else
        # This case should not be reached if called from main scripts with arg parsing
        die "For Ubuntu, please provide either --version or --codename."
    fi

    # Final check
    if [[ -z "$DIST_VERSION" || -z "$DIST_CODENAME" ]]; then
        die "Could not resolve version/codename for $dist. Input: version='$version_in', codename='$codename_in'."
    fi

    log_info "Resolved to: $dist $DIST_VERSION ($DIST_CODENAME)"
}

# Get default Ubuntu codename (used by multiple scripts)
get_default_ubuntu_codename() {
    local version
    version=$(_get_latest_ubuntu_version)
    if [[ -n "$version" ]]; then
        _get_ubuntu_codename_for_version "$version"
    else
        echo "plucky"  # Fallback to current development release
    fi
}

# --- Finalization ---
log_debug "Common library initialized."
